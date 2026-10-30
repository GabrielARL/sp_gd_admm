#!/usr/bin/env python3
"""Verify the focused BP-versus-projected-L-BFGS state-boundary animation."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import shutil
import subprocess
import sys
import tempfile
from html.parser import HTMLParser
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent
HTML_PATH = ROOT / "bp_lbfgs_state_boundary_animation.html"
SOURCE_REL = Path("experiments/rq1_endpoint_001/results/2026-10-28_endpoint_v3/trace.json")
SOURCE_SHA256 = "c47e200c5be707b66e9fc454ee221671c4eb36771aedac6e143719b6a679e2f9"
KATEX_JS = (
    'src="https://cdnjs.cloudflare.com/ajax/libs/KaTeX/0.16.11/katex.min.js" '
    'integrity="sha384-7zkQWkzuo3B5mTepMUcHkMB5jZaolc2xDwL6VFqjFALcbeS9Ggm/Yr2r3Dy4lfFg"'
)
KATEX_CSS = (
    'href="https://cdnjs.cloudflare.com/ajax/libs/KaTeX/0.16.11/katex.min.css" '
    'integrity="sha384-nB0miv6/jRmo5UMMR1wu3Gz6NLsoTkbqJghGIsx//Rlm+ZU03BU6SQNC66uf4l5+"'
)


class AnimationDataParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.in_data = False
        self.parts: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag == "script" and dict(attrs).get("id") == "animation-data":
            self.in_data = True

    def handle_endtag(self, tag: str) -> None:
        if tag == "script" and self.in_data:
            self.in_data = False

    def handle_data(self, data: str) -> None:
        if self.in_data:
            self.parts.append(data)


class ElementTextParser(HTMLParser):
    """Collect rendered text from selected element IDs in a dumped browser DOM."""

    VOID_TAGS = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"}

    def __init__(self, targets: set[str]) -> None:
        super().__init__()
        self.targets = targets
        self.active: str | None = None
        self.depth = 0
        self.parts: dict[str, list[str]] = {target: [] for target in targets}

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        element_id = dict(attrs).get("id")
        if self.active is None and element_id in self.targets:
            self.active = element_id
            self.depth = 1
        elif self.active is not None and tag not in self.VOID_TAGS:
            self.depth += 1

    def handle_endtag(self, tag: str) -> None:
        if self.active is None or tag in self.VOID_TAGS:
            return
        self.depth -= 1
        if self.depth == 0:
            self.active = None

    def handle_data(self, data: str) -> None:
        if self.active is not None:
            self.parts[self.active].append(data)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def extract_data(html: str) -> dict[str, Any]:
    parser = AnimationDataParser()
    parser.feed(html)
    if not parser.parts:
        raise AssertionError("missing animation-data JSON")
    return json.loads("".join(parser.parts))


def extract_element_text(html: str, *element_ids: str) -> dict[str, str]:
    parser = ElementTextParser(set(element_ids))
    parser.feed(html)
    return {
        element_id: " ".join(" ".join(parser.parts[element_id]).split())
        for element_id in element_ids
    }


def numeric_count(value: Any) -> int:
    if isinstance(value, bool):
        return 0
    if isinstance(value, (int, float)):
        return 1
    if isinstance(value, dict):
        return sum(numeric_count(item) for item in value.values())
    if isinstance(value, list):
        return sum(numeric_count(item) for item in value)
    return 0


def assert_in_order(text: str, tokens: list[str], label: str) -> None:
    position = 0
    for token in tokens:
        found = text.find(token, position)
        if found < 0:
            raise AssertionError(f"{label}: missing {token!r} after position {position}: {text!r}")
        position = found + len(token)


def signed_fixed(value: float, digits: int = 6) -> str:
    normalized = 0.0 if abs(value) < 0.5 * 10 ** (-digits) else float(value)
    prefix = "+" if normalized >= 0.0 else ""
    return f"{prefix}{normalized:.{digits}f}".replace("-", "−")


def close(actual: float, expected: float, label: str, tolerance: float = 1e-12) -> None:
    if not math.isclose(float(actual), float(expected), rel_tol=0.0, abs_tol=tolerance):
        raise AssertionError(f"{label}: {actual!r} != {expected!r}")


def close_vector(actual: list[float], expected: list[float], label: str, tolerance: float = 1e-12) -> None:
    if len(actual) != len(expected):
        raise AssertionError(f"{label}: length {len(actual)} != {len(expected)}")
    for index, (observed, retained) in enumerate(zip(actual, expected)):
        close(observed, retained, f"{label}[{index}]", tolerance)


def native_fingerprint(trace: dict[str, Any]) -> dict[str, Any]:
    for fingerprint in trace["fingerprints"]:
        if fingerprint["card_id"] == "RQ1-ENDPOINT-PG-001":
            return fingerprint["payload"]
    raise AssertionError("retained projected-gradient fingerprint is missing")


def check_source_and_math(data: dict[str, Any]) -> int:
    assert data["schema"] == "bp-lbfgs-state-boundary-animation/v2"
    assert data["beat_count"] == 10
    assert data["source"]["path"] == SOURCE_REL.as_posix(), "HTML source path is not the authorized retained trace"
    assert data["source"]["sha256"] == SOURCE_SHA256, "HTML source digest is not the authorized retained digest"
    source = ROOT / SOURCE_REL
    assert source.is_file(), f"missing retained source: {source}"
    observed_hash = sha256(source)
    assert observed_hash == SOURCE_SHA256, (
        f"source hash changed: {observed_hash} != {SOURCE_SHA256}"
    )
    trace = json.loads(source.read_text(encoding="utf-8"))
    assert trace["status"] == "valid"
    assert trace["validation_passed"] is True
    assert trace["bp_card"]["passed"] is True
    assert trace["coordinate_card"]["passed"] is True

    assert data["graph"]["checks"] == trace["graph"]["checks"]
    bp = data["bp"]
    close_vector(bp["L"], trace["channel_evidence"]["L_bit1_positive"], "BP L")
    bp_iterations = trace["bp_card"]["control"]["iterations"]
    close_vector(bp["q1"], bp_iterations[0]["q_bit1"], "BP Q iteration 1")
    close_vector(bp["u1"], bp_iterations[0]["u_bit1"], "BP U iteration 1")
    close_vector(bp["posterior1"], bp_iterations[0]["posterior_bit1"], "BP posterior iteration 1")
    close_vector(bp["q2"], bp_iterations[1]["q_bit1"], "BP Q iteration 2")
    close_vector(bp["u0"], [0.0, 0.0, 0.0, 0.0], "BP initial U")

    # Independently reproduce the displayed variable-node recurrence.
    expected_q1 = [bp["L"][0], bp["L"][1], bp["L"][1], bp["L"][2]]
    expected_q2 = [
        bp["L"][0],
        bp["L"][1] + bp["u1"][2],
        bp["L"][1] + bp["u1"][1],
        bp["L"][2],
    ]
    close_vector(bp["q1"], expected_q1, "recomputed BP Q iteration 1")
    close_vector(bp["q2"], expected_q2, "recomputed BP Q iteration 2")
    assert bp["q1"][1] == bp["q1"][2], "iteration-1 equality no longer holds"
    assert not math.isclose(bp["q2"][1], bp["q2"][2], rel_tol=0.0, abs_tol=1e-12), (
        "iteration-2 recipient distinction disappeared"
    )

    obj = data["objective"]
    close_vector(obj["ell"], trace["channel_evidence"]["ell_bit0_positive"], "objective-anchor ell")
    # The page's J is the channel rung's objective (channel and parity terms, no binary term)
    # multiplied by n = 3: that removes the rung's 1/n factor without moving its minimizers.
    assert obj["anchor_card"] == "RQ1-BRIDGE-CHANNEL-001", "objective anchor is not the channel rung"
    anchor = next(r for r in trace["rung_results"] if r["card_id"] == obj["anchor_card"])
    scale = obj["anchor_scale"]
    assert scale == len(obj["x0"]) == 3, "the anchor scale must be n = 3"
    first = anchor["result"]["trace"][0]
    close_vector(obj["x0"], first["x_before"], "objective-anchor x0")
    close_vector(obj["gradient"], [scale * value for value in first["gradient"]], "objective-anchor gradient times n")
    close(obj["loss_before"], scale * first["loss_before"], "objective-anchor J(x0) times n")
    fingerprint = next(f["payload"] for f in trace["fingerprints"] if f["card_id"] == obj["anchor_card"])
    close(obj["weights"]["channel"], fingerprint["channel_weight"], "channel weight")
    close(obj["weights"]["parity"], fingerprint["parity_weight"], "parity weight")
    close(fingerprint["binary_weight"], 0.0, "anchor rung binary weight")
    assert set(obj["weights"]) == {"channel", "parity"}, "the page's objective must have exactly two terms"

    x = obj["x0"]
    ell = obj["ell"]
    w_ch = obj["weights"]["channel"]
    w_par = obj["weights"]["parity"]
    checks = [(0, 1), (1, 2)]
    residuals: list[float] = []
    check_terms = [[0.0, 0.0], [0.0, 0.0]]
    parity = [0.0, 0.0, 0.0]
    for check_index, (left, right) in enumerate(checks):
        residual = 1.0 - x[left] * x[right]
        residuals.append(residual)
        g_left = -(2.0 * w_par) * residual * x[right]
        g_right = -(2.0 * w_par) * residual * x[left]
        check_terms[check_index] = [g_left, g_right]
        parity[left] += g_left
        parity[right] += g_right
    close(residuals[0], obj["residual"]["A"], "objective residual A")
    close(residuals[1], obj["residual"]["B"], "objective residual B")
    close_vector(check_terms[0], obj["g"]["A"], "objective check A terms")
    close_vector(check_terms[1], obj["g"]["B"], "objective check B terms")

    channel = [-(w_ch / 2.0) * value for value in ell]
    gradient = [parity[i] + channel[i] for i in range(3)]
    close_vector(channel, obj["channel_partial"], "objective channel partial")
    close_vector(gradient, obj["gradient"], "recomputed objective gradient")
    close(objective(obj, x), obj["loss_before"], "recomputed J(x0)")

    edge_count = len(data["graph"]["edge_order"])
    dimension = len(obj["x0"])
    memory_pairs = data["lbfgs"]["memory_pairs"]
    assert edge_count == len(bp["u0"]) == 4, "BP memory count must be one U scalar per Tanner-graph edge"
    assert (dimension, memory_pairs, dimension + 2 * dimension * memory_pairs) == (3, 10, 63), (
        "L-BFGS memory count must be x plus at most ten (s,y) vector pairs"
    )

    check_lbfgs(obj, data["lbfgs"])
    return numeric_count(bp) + numeric_count(obj) + numeric_count(data["lbfgs"])


def objective(obj: dict[str, Any], x: list[float]) -> float:
    """J(x) = -(w_ch / 2) sum_i ell_i x_i + w_par sum_c (1 - prod_{j in c} x_j)^2."""
    ell, w = obj["ell"], obj["weights"]
    channel = -(w["channel"] / 2.0) * sum(e * v for e, v in zip(ell, x))
    parity = w["parity"] * ((1.0 - x[0] * x[1]) ** 2 + (1.0 - x[1] * x[2]) ** 2)
    return channel + parity


def gradient_of(obj: dict[str, Any], x: list[float]) -> list[float]:
    ell, w = obj["ell"], obj["weights"]
    grad = [-(w["channel"] / 2.0) * e for e in ell]
    for left, right in ((0, 1), (1, 2)):
        residual = 1.0 - x[left] * x[right]
        grad[left] -= 2.0 * w["parity"] * residual * x[right]
        grad[right] -= 2.0 * w["parity"] * residual * x[left]
    return grad


def lbfgs_box_variant(obj: dict[str, Any], memory_limit: int, max_halvings: int) -> list[dict[str, Any]]:
    """Recompute the page's teaching variant from its explicit box, retention, and stop rules."""
    dot = lambda a, b: sum(p * q for p, q in zip(a, b))
    x = list(obj["x0"])
    pairs: list[tuple[list[float], list[float]]] = []
    steps = []
    for _ in range(100):
        grad = gradient_of(obj, x)
        held = [(x[i] >= 1.0 and grad[i] < 0.0) or (x[i] <= -1.0 and grad[i] > 0.0) for i in range(3)]
        free = lambda v: [0.0 if h else value for value, h in zip(v, held)]
        q = free(grad)
        if max(abs(value) for value in q) < 1e-9:
            break
        usable = [(free(s), free(y)) for s, y in pairs]
        usable = [(s, y) for s, y in usable if dot(s, y) > 1e-12]
        alphas = []
        for s, y in reversed(usable):
            rho = 1.0 / dot(y, s)
            a = rho * dot(s, q)
            alphas.append((a, rho, s, y))
            q = [qi - a * yi for qi, yi in zip(q, y)]
        gamma = dot(usable[-1][0], usable[-1][1]) / dot(usable[-1][1], usable[-1][1]) if usable else 1.0
        r = [gamma * value for value in q]
        for a, rho, s, y in reversed(alphas):
            b = rho * dot(y, r)
            r = [ri + si * (a - b) for ri, si in zip(r, s)]
        direction = [-value for value in r]
        before = objective(obj, x)
        alpha, accepted = 1.0, None
        for _halving in range(max_halvings + 1):
            raw = [xi + alpha * di for xi, di in zip(x, direction)]
            proposal = [min(1.0, max(-1.0, value)) for value in raw]
            if objective(obj, proposal) < before:
                accepted = (raw, proposal)
                break
            alpha /= 2.0
        if accepted is None:
            break
        raw, proposal = accepted
        new_grad = gradient_of(obj, proposal)
        s = [a - b for a, b in zip(proposal, x)]
        y = [a - b for a, b in zip(new_grad, grad)]
        steps.append({"x": x, "grad": grad, "gamma": gamma, "direction": direction, "alpha": alpha,
                      "raw": raw, "x_next": proposal, "loss_next": objective(obj, proposal), "grad_next": new_grad, "s": s, "y": y})
        if dot(s, y) > 1e-12:
            pairs = (pairs + [(s, y)])[-memory_limit:]
        x = proposal
    return steps


def check_lbfgs(obj: dict[str, Any], lb: dict[str, Any]) -> None:
    assert lb["memory_pairs"] == 10, "displayed retained-vector limit changed"
    assert lb["max_halvings"] == 16, "displayed line-search limit changed"
    steps = lbfgs_box_variant(obj, lb["memory_pairs"], lb["max_halvings"])
    assert len(steps) >= 2, "L-BFGS teaching variant stopped before its second update"
    first, second = steps[0], steps[1]
    close_vector(first["direction"], [-value for value in obj["gradient"]], "L-BFGS first direction is -grad J")
    close_vector(lb["d0"], first["direction"], "L-BFGS d0")
    close(lb["alpha0"], first["alpha"], "L-BFGS alpha0")
    trials, alpha = [], 1.0
    for _halving in range(lb["max_halvings"] + 1):
        proposal = [min(1.0, max(-1.0, xi + alpha * di)) for xi, di in zip(obj["x0"], first["direction"])]
        trials.append((alpha, objective(obj, proposal)))
        if trials[-1][1] < obj["loss_before"]:
            break
        alpha /= 2.0
    assert len(lb["trials0"]) == len(trials), "displayed first line-search trials differ in number"
    for index, ((shown_alpha, shown_loss), (alpha_k, loss_k)) in enumerate(zip(lb["trials0"], trials)):
        close(shown_alpha, alpha_k, f"first line-search alpha[{index}]")
        close(shown_loss, loss_k, f"first line-search J[{index}]")
    assert all(-1.0 < value < 1.0 for value in first["raw"]), "the page says the first step stays inside the box"
    close_vector(lb["x1"], first["x_next"], "L-BFGS x1")
    close(lb["loss1"], first["loss_next"], "L-BFGS J(x1)")
    close_vector(lb["grad1"], first["grad_next"], "L-BFGS grad J(x1)")
    close_vector(lb["s0"], first["s"], "L-BFGS s0")
    close_vector(lb["y0"], first["y"], "L-BFGS y0")
    close(lb["gamma1"], second["gamma"], "L-BFGS gamma1")
    close_vector(lb["d1"], second["direction"], "L-BFGS d1")
    close(lb["alpha1"], second["alpha"], "L-BFGS alpha1")
    close_vector(lb["raw2"], second["raw"], "L-BFGS raw step 2")
    close_vector(lb["x2"], second["x_next"], "L-BFGS x2")
    assert lb["raw2"][0] > 1.0, "second raw step no longer exceeds x1=1"
    close(lb["x2"][0], 1.0, "second update box projection")
    close(lb["loss2"], second["loss_next"], "L-BFGS J(x2)")
    path = [obj["x0"]] + [step["x_next"] for step in steps]
    assert len(lb["path"]) == len(path), f"L-BFGS path length {len(lb['path'])} != {len(path)}"
    for index, (shown, expected) in enumerate(zip(lb["path"], path)):
        close_vector(shown, expected, f"L-BFGS path[{index}]")
    close_vector(lb["loss_path"], [objective(obj, point) for point in path], "L-BFGS loss path")
    close(lb["loss_path"][0], obj["loss_before"], "L-BFGS starts at the retained J(x0)")
    assert all(b < a for a, b in zip(lb["loss_path"], lb["loss_path"][1:])), "L-BFGS loss is not strictly decreasing"
    final_gradient = gradient_of(obj, path[-1])
    final_held = [
        (path[-1][i] >= 1.0 and final_gradient[i] < 0.0)
        or (path[-1][i] <= -1.0 and final_gradient[i] > 0.0)
        for i in range(3)
    ]
    final_free_gradient = [0.0 if held else value for held, value in zip(final_held, final_gradient)]
    assert max(abs(value) for value in final_free_gradient) < 1e-9, (
        "embedded path does not satisfy the displayed free-gradient stop"
    )
    bits = [0 if value >= 0.0 else 1 for value in path[-1]]
    assert (bits[0] ^ bits[1], bits[1] ^ bits[2]) == (0, 0), f"final hard-decision estimate {bits} is not a codeword"


def check_wording_and_structure(html: str) -> None:
    visible = re.sub(r"<script\b.*?</script>", " ", html, flags=re.IGNORECASE | re.DOTALL)
    visible = re.sub(r"<style\b.*?</style>", " ", visible, flags=re.IGNORECASE | re.DOTALL)
    prohibited = re.compile(
        r"\bADMM\b|matched[ -]inputs?|input[ -]matched|common inputs|same inputs|"
        r"identical[ -]inputs?|gradient messages?|hard word|hard decision|"
        r"stored pairs?|retained vectors?|gradient coordinate|box wall|"
        r"projected L-BFGS|L-BFGS with box projection|AWGN log-likelihood|BPSK over AWGN|"
        r"Constant rule|Sum rule|Constant multiple|Square of a difference|"
        r"\bGD\s+(?:sends|returns|delivers)\b",
        flags=re.IGNORECASE,
    )
    match = prohibited.search(visible) or prohibited.search(html)
    assert match is None, f"prohibited or misleading wording: {match.group(0)!r}"
    required = (
        "Matching beats align the visual comparison; they do not imply equal arithmetic, storage, or computational work.",
        "Fixed graph and channel evidence; stated L-BFGS objective function",
        "All L-BFGS terms shown for A then B are calculated from the same frozen x before one update; A then B is presentation order, not a sequential update.",
        "dashed cards are temporary calculations, not messages",
        "up to ten earlier",
        "hard-decision estimate",
        "this page places the iteration boundary after the check calculation",
        "constructed teaching variant",
        r"Across the next iteration, L-BFGS keeps $\mathbf{x}^{(1)}$, $\mathbf{s}^{(0)}$, and $\mathbf{y}^{(0)}$",
        "The subsequent L-BFGS trajectory is generated by the explicit rules on this page",
        "not the retained projected-gradient-descent endpoint",
        "not the L-BFGS implementation used elsewhere in JadeJcade",
        "not evidence for the active BP–projected-GD research question",
        "is halved at most 16 times",
        r"Set $\mathbf{q}\leftarrow[\nabla J]_{F_t}$",
        "For usable pairs, newest to oldest",
        "For the same pairs, oldest to newest",
        r"\gamma_t=(\mathbf{s}^\top\mathbf{y})/(\mathbf{y}^\top\mathbf{y})",
        r"\max_{i\in F_t}|\partial J/\partial x_i|<10^{-9}",
        "after $100$ accepted updates",
        "It does not establish error rate, convergence, complexity, or decoder superiority over a code ensemble.",
        "independently recomputed by this artifact’s verifier",
        '"Terms that do not change"',
        '"Differentiate the remaining terms"',
        '"Chain rule"',
        '"Hold x₂ fixed"',
        '"Channel model"',
        "With BPSK modulation",
        "In an AWGN channel",
        r"does not treat $x_i^2$ as constant inside the box",
        '"Expand the square"',
        '"Drop constants"',
        "Form the two variable-to-check messages addressed to A",
        r"Q^{(t)}_{i\to c}",
        r"\sum_{c'\in N(i)\setminus\{c\}}",
        r"U^{(t-1)}_{c'\to i}",
        r"r_c = 1-",
        r"g_{c,i} = -",
        r"Send to $c$; sum $U$ only from the other checks.",
        r"N(${I})\setminus\{${A}\}",
        r"N(${I})=${crossedNbr}\quad\Longrightarrow\quad \htmlClass{mN}{${allowed}}=\htmlClass{mS}{${set(rest)}}",
        'tag: `DROP ${A}`',
        "moveTeachingChip",
        "bpCombinationCue",
        "function bpPhaseBadge",
        'node.dataset.cue = "bp-combine"',
        '.chip.stored-input',
        '.chip.read-copy',
        '.bp-phase',
        'kept.dataset.role = visualReadBeat ? "stored-input" : "kept-input"',
        'rhsToken.dataset.role = other === null ? "empty-sum" : "read-copy"',
        'result.dataset.stage = "new-output"',
        'G.svg.dataset[`${cueKey}ReadAt`]',
        'if (opts.stop !== false) addStop',
        "frozen U⁽⁰⁾ · read only",
        "All $Q^{(1)}$ read frozen $U^{(0)}$.",
        "READ a copy → COMBINE at the bit → CREATE new $Q$ → SEND $Q$.",
        "grow(used, tUse",
        ".chip.excluded",
        'omitted.dataset.message = `U^(${iter - 1})_${CHECK[a]}->${i + 1}`',
        "Tanner-graph edges stay",
        "Bit 2 is speaking to check A.",
        r"Here $U^{(0)}_{B\to 2}=0$",
        ">Play beat</button>",
        ">Next beat →</button>",
        'const label = tour.on ? "Next step"',
        'atEnd ? "Replay beat"',
        "function resetCurrentBeat()",
        "getInteractionState",
        "Presentation step ${stepNumber} of ${total}",
        "Next visual change",
        "Dimmed = context, not removed",
        "Presentation clock waits for your click",
        "Reveal step ${stepNumber}",
        "bit2CueMatches",
        'root.dataset.tourSmokeBit2Cue = "passed"',
        "beat5BpVisualMatches",
        'root.dataset.tourSmokeBeat5BpVisual = "passed"',
        'class="memory-box" id="bp-memory"',
        'class="memory-box" id="lbfgs-memory"',
        "function renderMemoryBoxes",
        "MEMORY CONSUMPTION",
        "one U per Tanner-graph edge",
        "configured cap",
        "Retained floating-point state only; fixed channel evidence, graph structure, and temporary arithmetic are excluded.",
        "const memoryBoxMatches =",
        'root.dataset.tourSmokeMemoryBox = "passed"',
        "gold double arrows = connections · blue dashed arrows = BP messages",
        'tag: `DROP ${A}`',
        r"\text{KEEP }U",
        r"\text{DROP }\cancel{U",
        "tour-guide",
        "it grows as a product moves away from $+1$",
        "the displayed fixed-rule L-BFGS path is recomputed for this scaled $J$",
        "Carried from Beat 3",
        "A is joined to two bits in both panels; the retained state differs",
        "retained by edge",
        "retained by bit",
        "temporary this update",
        "dashed = input dependence; solid teal = g-to-bit pairing; neither is message motion",
        "Two check-to-variable messages, one along each edge from A.",
        "Two g terms, one for each bit joined to A.",
        "derivative-contribution",
        'q.line.dataset.handoff = "bp-q"',
        'read.dataset.handoff = "lbfgs-x-read"',
        'readout.dataset.handoff = "beat3-poly-readout"',
        "beat4HandoffMatches",
        "beat4ParallelMatches",
        "graphToBoxBridgeMatches",
        "frozenAccumulationMatches",
        "beat7CausalMatches",
        "the three scalars become the coordinates of one point",
        "it does not replace the Tanner graph",
        "First assemble $\\nabla J(\\mathbf{x}^{(0)})$, then form $\\mathbf{d}^{(0)}$; movement waits.",
    )
    lowered = html.lower()
    for phrase in required:
        assert phrase.lower() in lowered, f"required explanation is missing: {phrase!r}"
    for stale in (
        "only check ${rest.join",
        "message comes back to bit",
        "because the other incoming",
        "Leave out check ${A}",
        'class: "strike"',
        ".graph .strike",
        "setTimeout(() => { if (!playing && !frozen && current === 0) play(); }, 900)",
        "function advance()",
        "Show ${labels.length} synchronized actions",
        "beckon 1.6s",
        r"Q^{(t)}_{i\to a}",
        r"\sum_{b\in N(i)\setminus a}",
        r"$N(i)\setminus a$ changes only this sum’s index set.",
        r"Q_{i\to a}",
        r"g_{a,i}",
        r"r_a = 1-",
    ):
        assert stale not in html, f"stale wording or automatic-advance behavior remains: {stale!r}"
    assert html.count('class="lane ') == 2, "expected exactly two method lanes"
    assert html.count('class="state-memory-row"') == 2, "each method lane needs one state-and-memory row"
    assert html.count('id="bp-memory"') == 1 and html.count('id="lbfgs-memory"') == 1, (
        "each method lane needs exactly one separate memory-consumption box"
    )
    assert html.count('dot.className = "dot"') == 1, "timeline generator is missing or duplicated"
    assert '<button class="dot"' not in html, "timeline dots must not be duplicated statically"
    assert 'tour.next.className = "tour-next"' in html and "function tourNext()" in html, "tutorial mode is missing"
    assert "function runTourSmoke()" in html, "tutorial interaction smoke test is missing"
    assert "if (!zoomed || smoke) return;" in html, "enlarged tutorial must be click-driven"
    assert "if (reduced)" in html and "tourArrive();" in html, "reduced-motion stepping must complete on click without timed motion"
    cue_patterns = {
        "bit-2 focus cue": r'["\']bit-2-focus["\']',
        "bit-2 adjacency cue": r'["\']bit-2-adjacency["\']',
        "adjacency relation": r'["\']data-relation["\']\s*:\s*["\']adjacency["\']',
        "bit-2 adjacency origin": r'["\']data-from-bit["\']\s*:',
        "adjacency check address": r'["\']data-check["\']\s*:',
    }
    for label, pattern in cue_patterns.items():
        assert re.search(pattern, html), f"missing {label} data hook"
    assert re.search(r'class\s*:\s*["\']bit-sparkle["\']', html), "bit-2 focus cue lacks sparkle elements"
    assert re.search(r'class\s*:\s*["\']neighbour-arrow["\']', html), "bit-2 adjacency cue lacks neighbour arrows"
    assert sorted(re.findall(r'class="zoom-btn" type="button" data-zoom="(\w+)"', html)) == ["bp", "lbfgs", "poly"], (
        "each of the three panels needs one enlarge button"
    )
    assert '"beat_count": 10' in html
    for asset in (KATEX_JS, KATEX_CSS):
        assert asset in html, f"pinned KaTeX asset with integrity hash is missing: {asset[:60]}..."
    assert html.count('R`\\neq`, "sign")') == 2 and html.count('"=", "sign")') == 2, "iteration-2 sign chips are missing"


def dump_dom(
    browser: str,
    url: str,
    virtual_time_budget: int,
    window_size: str = "1910,940",
    extra_args: tuple[str, ...] = (),
) -> str:
    with tempfile.TemporaryDirectory(prefix="bp-lbfgs-state-animation-chrome-") as profile:
        command = [
            browser,
            "--headless=new",
            "--no-sandbox",
            "--disable-gpu",
            "--disable-dev-shm-usage",
            "--allow-file-access-from-files",
            f"--window-size={window_size}",
            f"--user-data-dir={profile}",
            f"--virtual-time-budget={virtual_time_budget}",
            *extra_args,
            "--dump-dom",
            url,
        ]
        completed = subprocess.run(command, capture_output=True, text=True, timeout=90, check=False)
    if completed.returncode != 0:
        raise AssertionError(f"headless browser exited {completed.returncode}:\n{completed.stderr[-1200:]}")
    assert 'data-animation-ready="true"' in completed.stdout, "browser initialization did not finish"
    return completed.stdout


def browser_smoke(data: dict[str, Any]) -> str:
    browser = next(
        (
            path
            for name in ("google-chrome", "chromium", "chromium-browser")
            if (path := shutil.which(name)) is not None
        ),
        None,
    )
    if browser is None:
        return "skipped (no Chrome/Chromium executable)"
    base_url = HTML_PATH.resolve().as_uri()
    smoke_dom = dump_dom(browser, base_url + "?smoke=1", 2500)
    assert 'data-math="katex"' in smoke_dom, "KaTeX did not load; equations fell back to TeX source"
    assert 'class="katex-error"' not in smoke_dom, "KaTeX reported a TeX error"
    assert 'data-animation-smoke="passed"' in smoke_dom, "browser smoke did not pass"
    assert 'data-animation-smoke-beats="10"' in smoke_dom, "not every beat rendered"
    overflow = re.search(r'data-layout-overflow="([^"]*)"', smoke_dom)
    assert overflow is not None and overflow.group(1) == "none", (
        f"one-screen layout clips content at 1910x940: {overflow.group(1) if overflow else 'not measured'}"
    )
    assert "Beat 1 of 10" in smoke_dom, "smoke cycle did not reset to beat 1"

    tour_gates = (
        "controls",
        "load-idle",
        "play-beat",
        "zoom-idle",
        "grouping",
        "keyboard",
        "close",
        "focus",
        "single-step",
        "step-idle",
        "clarity",
        "visibility",
        "next-beat-label",
        "beat",
        "handoff",
        "parallel",
        "bit2-cue",
        "beat5-bp-visual",
        "memory-box",
        "bridge",
        "frozen",
        "causal",
        "finish",
    )
    for window_size in ("1910,940", "800,700"):
        tour_dom = dump_dom(browser, base_url + "?tour-smoke=1", 8000, window_size=window_size)
        tour_error = re.search(r'data-tour-smoke-error="([^"]*)"', tour_dom)
        assert 'data-tour-smoke="passed"' in tour_dom, (
            f"tutorial interaction smoke failed at {window_size}: "
            f"{tour_error.group(1) if tour_error else 'no completed result'}"
        )
        for gate in tour_gates:
            assert f'data-tour-smoke-{gate}="passed"' in tour_dom, (
                f"tutorial interaction gate did not pass at {window_size}: {gate}"
            )

    reduced_dom = dump_dom(
        browser,
        base_url + "?tour-smoke=1",
        8000,
        window_size="800,700",
        extra_args=("--force-prefers-reduced-motion=reduce",),
    )
    reduced_error = re.search(r'data-tour-smoke-error="([^"]*)"', reduced_dom)
    assert 'data-tour-smoke-motion="reduced"' in reduced_dom, "browser did not enter reduced-motion mode"
    assert 'data-tour-smoke="passed"' in reduced_dom, (
        "reduced-motion tutorial interaction smoke failed: "
        f"{reduced_error.group(1) if reduced_error else 'no completed result'}"
    )
    for gate in tour_gates:
        assert f'data-tour-smoke-{gate}="passed"' in reduced_dom, (
            f"reduced-motion tutorial interaction gate did not pass: {gate}"
        )

    snapshots = extract_element_text(
        smoke_dom,
        "smoke-beat3-bp-explain",
        "smoke-beat3-bp-hover",
        "smoke-beat4-bp-state",
        "smoke-beat4-lbfgs-state",
        "smoke-beat4-bp-hover",
        "smoke-beat4-lbfgs-hover",
        "smoke-beat7-bp-math",
        "smoke-beat7-lbfgs-math",
        "smoke-beat8-lbfgs-math",
        "smoke-beat9-bp-math",
        "smoke-beat9-lbfgs-math",
        "smoke-beat9-poly",
        "smoke-beat10-poly",
    )
    bp = data["bp"]
    obj = data["objective"]
    lb = data["lbfgs"]
    assert_in_order(
        snapshots["smoke-beat3-bp-explain"],
        ["Bit 2 is speaking to check A.", "check-to-variable message", "leaves out A’s preceding check-to-variable message"],
        "rendered recipient-exclusion explanation",
    )
    assert_in_order(
        snapshots["smoke-beat3-bp-hover"],
        ["Q2→A", "KEEP B", "Build Q2→A", "send it to A"],
        "rendered recipient-exclusion formula note",
    )
    assert_in_order(
        snapshots["smoke-beat4-bp-state"],
        ["retained by edge", signed_fixed(bp["u1"][0], 3), signed_fixed(bp["u1"][1], 3), "UB→2=0", "UB→3=0"],
        "rendered Beat-4 BP retained edge state",
    )
    assert_in_order(
        snapshots["smoke-beat4-lbfgs-state"],
        [
            "retained by bit",
            *[signed_fixed(value, 3) for value in obj["x0"]],
            "temporary this update",
            *[signed_fixed(value, 3) for value in obj["g"]["A"]],
        ],
        "rendered Beat-4 retained x and temporary g terms",
    )
    assert_in_order(
        snapshots["smoke-beat4-bp-hover"],
        ["Two check-to-variable messages", "one along each edge from A", "Both remain in the U slots above"],
        "rendered Beat-4 BP fan-out conclusion",
    )
    assert_in_order(
        snapshots["smoke-beat4-lbfgs-hover"],
        ["Two g terms", "one for each bit joined to A", "They are temporary", "x remains in retained state"],
        "rendered Beat-4 L-BFGS fan-out conclusion",
    )
    assert_in_order(
        snapshots["smoke-beat7-bp-math"],
        [signed_fixed(value) for value in bp["posterior1"]],
        "rendered BP posterior",
    )
    beat7_lbfgs_math = snapshots["smoke-beat7-lbfgs-math"]
    assert_in_order(
        beat7_lbfgs_math,
        [
            signed_fixed(obj["g"]["A"][1]),
            signed_fixed(obj["g"]["B"][0]),
            signed_fixed(obj["channel_partial"][1]),
            signed_fixed(obj["gradient"][1]),
            *[signed_fixed(value) for value in lb["d0"]],
            signed_fixed(lb["x1"][1]),
        ],
        "rendered L-BFGS partial derivative and first update",
    )
    for _alpha, trial_loss in lb["trials0"]:
        assert f"{trial_loss:.6f}" in beat7_lbfgs_math, "a first line-search trial loss is not rendered"
    assert f"{obj['loss_before']:.6f}" in beat7_lbfgs_math, "J(x0) is not rendered with the line-search trials"
    (alpha1, _loss1), (alpha2, _loss2), (alpha3, _loss3) = lb["trials0"]
    for alpha in (alpha1, alpha2, alpha3):
        assert f"Jα={alpha:g}" in beat7_lbfgs_math, f"line-search trial α={alpha:g} is not labelled"
    assert beat7_lbfgs_math.count(">") >= 2 and beat7_lbfgs_math.count("<") >= 1, (
        "the first line-search card does not visibly distinguish two rejected trials from the accepted trial"
    )
    assert beat7_lbfgs_math.count("reject") == 2, "the two rejected first-step trials are not labelled"
    assert f"accept: α0={lb['alpha0']:g}" in beat7_lbfgs_math, "the accepted first line-search step is not visibly identified"
    assert_in_order(
        snapshots["smoke-beat8-lbfgs-math"],
        [signed_fixed(value) for value in lb["x1"] + lb["s0"] + lb["y0"]],
        "rendered L-BFGS x, s, and y values across the iteration",
    )
    assert_in_order(
        snapshots["smoke-beat9-bp-math"],
        [signed_fixed(bp["q2"][1]), signed_fixed(bp["q2"][2])],
        "rendered recipient-indexed BP Q values",
    )
    assert_in_order(
        snapshots["smoke-beat9-lbfgs-math"],
        ["A reads x2(1)", signed_fixed(lb["x1"][1]), "B reads x2(1)", signed_fixed(lb["x1"][1])],
        "rendered shared x2 reads",
    )
    direction_norm = math.sqrt(sum(value * value for value in lb["d1"]))
    gradient_norm = math.sqrt(sum(value * value for value in lb["grad1"]))
    direction_ratio = direction_norm / gradient_norm
    cosine = -sum(a * b for a, b in zip(lb["d1"], lb["grad1"])) / (direction_norm * gradient_norm)
    turn_degrees = math.degrees(math.acos(max(-1.0, min(1.0, cosine))))
    assert_in_order(
        snapshots["smoke-beat9-poly"],
        [f"{direction_ratio:.2f}", f"{turn_degrees:.0f}", f"{lb['raw2'][0]:.3f}", "sets x1=1"],
        "rendered L-BFGS second-direction geometry and box projection",
    )
    assert_in_order(
        snapshots["smoke-beat10-poly"],
        [f"After {len(lb['path']) - 1} updates", "000", signed_fixed(lb["loss_path"][-1])],
        "rendered L-BFGS endpoint in the box",
    )

    # Seek into beat 3. Q_{1->A} is first explained as N(1) \\ A, so its substitution starts later:
    # at 5600 ms the derivations are morphing, at 19000 ms L_1 is flying into Q_{1->A},
    # and at 20500 ms the Q_{1->A} label is travelling along its edge.
    substitution_dom = dump_dom(browser, base_url + "?at=19000#beat=3", 2500)
    assert 'class="katex flying"' in substitution_dom, "no value is being substituted into an equation at beat 3, 19000 ms"
    travel_dom = dump_dom(browser, base_url + "?at=20500#beat=3", 2500)
    assert 'class="chip bp hot travelling' in travel_dom, "no BP message label is travelling along its edge at beat 3, 20500 ms"
    morph_dom = dump_dom(browser, base_url + "?at=5600#beat=3", 2500)
    assert 'class="sparkle"' in morph_dom, "the r_A derivation is not sparkling between two steps at beat 3, 5600 ms"
    cue_dom = dump_dom(browser, base_url + "?at=2700#beat=3", 2500)
    cues = re.findall(r'<i class="next-cue"(?: style="([^"]*)")?>', cue_dom)
    assert any("opacity: 0;" not in (style or "") for style in cues), (
        "no next-expression triangle is showing before the first derivation change at beat 3, 2700 ms"
    )

    endpoint_time = 900 + (len(lb["path"]) - 1) * 700
    before_endpoint = dump_dom(browser, base_url + f"?at={endpoint_time - 500}#beat=10", 2500)
    before_tag = re.search(r'<div class="poly-readout" id="poly-readout"[^>]*>', before_endpoint)
    assert before_tag is not None and "opacity: 0" in before_tag.group(0), (
        "beat-10 conclusion appears before the box path reaches its endpoint"
    )
    after_endpoint = dump_dom(browser, base_url + f"?at={endpoint_time + 800}#beat=10", 2500)
    after_tag = re.search(r'<div class="poly-readout" id="poly-readout"[^>]*>', after_endpoint)
    assert after_tag is not None and "opacity: 0" not in after_tag.group(0), (
        "beat-10 conclusion remains hidden after the box path reaches its endpoint"
    )
    endpoint_text = extract_element_text(after_endpoint, "poly-readout")["poly-readout"]
    assert_in_order(
        endpoint_text,
        [f"After {len(lb['path']) - 1} updates", "000", f"{abs(lb['loss_path'][-1]):.6f}"],
        "timed L-BFGS endpoint conclusion",
    )
    return f"passed ({Path(browser).name})"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--skip-browser", action="store_true", help="skip the available headless-browser smoke test")
    args = parser.parse_args()

    html = HTML_PATH.read_text(encoding="utf-8")
    data = extract_data(html)
    value_count = check_source_and_math(data)
    check_wording_and_structure(html)
    browser = "skipped by request" if args.skip_browser else browser_smoke(data)
    print(
        f"PASS: retained BP/objective-anchor hash, {value_count} embedded values, BP replay, "
        f"objective/gradient checks, L-BFGS teaching-variant replay, wording gates, browser smoke {browser}."
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, KeyError, ValueError, json.JSONDecodeError, subprocess.TimeoutExpired) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
