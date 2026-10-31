#!/usr/bin/env python3
"""Verify the focused BP-versus-ADMM state-boundary animation."""

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
HTML_PATH = ROOT / "bp_admm_state_boundary_animation.html"
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
    assert data["schema"] == "bp-admm-state-boundary-animation/v1"
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
    close_vector(obj["ell"], trace["channel_evidence"]["ell_bit0_positive"], "channel-evidence ell")
    assert obj["anchor_card"] == "RQ1-BRIDGE-CHANNEL-001", "x0 anchor is not the channel rung"
    anchor = next(r for r in trace["rung_results"] if r["card_id"] == obj["anchor_card"])
    close_vector(obj["x0"], anchor["result"]["trace"][0]["x_before"], "retained x0")
    close_vector(obj["x0"], [math.tanh(value / 2.0) for value in obj["ell"]], "x0 = tanh(ell / 2)")
    close(obj["objective_before"], -0.5 * sum(e * v for e, v in zip(obj["ell"], obj["x0"])), "decoding objective at x0")
    check_admm(obj, data["admm"])
    return numeric_count(bp) + numeric_count(obj) + numeric_count(data["admm"])

def admm_run(ell: list[float], x0: list[float], rho: float, tolerance: float, max_iterations: int) -> list[dict[str, Any]]:
    """Scaled ADMM for LP decoding as the page states it, in +-1 coordinates on checks A = {1, 2} and B = {2, 3}.

    Each iteration runs the replica update z_a = Pi_{P_a}(S_a x + u_a) onto the segment {(t, t): |t| <= 1},
    the scaled dual update u_a += S_a x - z_a, then the exact box-clipped x-update
    x_i = clip((sum_a (z_a,i - u_a,i) + ell_i / (2 rho)) / d_i). It starts from x0, u = 0 and z0_a = S_a x0,
    and stops when the primal residual max|S_a x - z_a| and the dual residual rho max|z - z_prev| are below tolerance.
    """
    checks = ((0, 1), (1, 2))
    clip = lambda value: min(1.0, max(-1.0, value))
    x = list(x0)
    u = [[0.0, 0.0], [0.0, 0.0]]
    z = [[x[a], x[b]] for a, b in checks]
    steps = []
    for _ in range(max_iterations):
        z_prev = [list(row) for row in z]
        view = [[x[a] + u[c][0], x[b] + u[c][1]] for c, (a, b) in enumerate(checks)]
        t = [clip((first + second) / 2.0) for first, second in view]
        z = [[value, value] for value in t]
        u = [[u[c][0] + x[a] - z[c][0], u[c][1] + x[b] - z[c][1]] for c, (a, b) in enumerate(checks)]
        total = [value / (2.0 * rho) for value in ell]
        degree = [0, 0, 0]
        for c, (a, b) in enumerate(checks):
            for j, i in enumerate((a, b)):
                total[i] += z[c][j] - u[c][j]
                degree[i] += 1
        x_new = [clip(total[i] / degree[i]) for i in range(3)]
        primal = max(abs((x_new[a], x_new[b])[j] - z[c][j]) for c, (a, b) in enumerate(checks) for j in range(2))
        dual = rho * max(abs(z[c][j] - z_prev[c][j]) for c in range(2) for j in range(2))
        steps.append({"view": view, "t": t, "z": z, "u": u, "x": x_new, "primal": primal, "dual": dual})
        x = x_new
        if primal < tolerance and dual < tolerance:
            break
    return steps


def check_admm(obj: dict[str, Any], ad: dict[str, Any]) -> None:
    assert ad["rho"] == 1.0 and ad["tolerance"] == 1e-6 and ad["max_iterations"] == 500, "displayed ADMM settings changed"
    assert ad["u0"] == [[0.0, 0.0], [0.0, 0.0]], "scaled dual variables must start at zero"
    steps = admm_run(obj["ell"], obj["x0"], ad["rho"], ad["tolerance"], ad["max_iterations"])
    assert len(steps) >= 2, "ADMM stopped before its second iteration"
    first, second = steps[0], steps[1]
    for label, shown, expected in (("v1", ad["v1"], first["view"]), ("z1", ad["z1"], first["z"]), ("u1", ad["u1"], first["u"]),
                                   ("v2", ad["v2"], second["view"]), ("z2", ad["z2"], second["z"]), ("u2", ad["u2"], second["u"])):
        for c in range(2):
            close_vector(shown[c], expected[c], f"ADMM {label}[{c}]")
    close_vector(ad["t1"], first["t"], "ADMM t1")
    for c in range(2):
        close_vector(ad["targets1"][c], [first["z"][c][j] - first["u"][c][j] for j in range(2)], f"ADMM z1 - u1 [{c}]")
    close_vector(ad["x1"], first["x"], "ADMM x1")
    close_vector(ad["x2"], second["x"], "ADMM x2")
    close(ad["primal1"], first["primal"], "ADMM primal residual 1")
    close(ad["dual1"], first["dual"], "ADMM dual residual 1")
    path = [obj["x0"]] + [step["x"] for step in steps]
    assert len(ad["path"]) == len(path), f"ADMM path length {len(ad['path'])} != {len(path)}"
    for index, (shown, expected) in enumerate(zip(ad["path"], path)):
        close_vector(shown, expected, f"ADMM path[{index}]")
    close_vector(ad["objective_path"], [-0.5 * sum(e * v for e, v in zip(obj["ell"], point)) for point in path], "ADMM objective path")
    close_vector(ad["primal_path"], [step["primal"] for step in steps], "ADMM primal residuals")
    close_vector(ad["dual_path"], [step["dual"] for step in steps], "ADMM dual residuals")
    assert steps[-1]["primal"] < ad["tolerance"] and steps[-1]["dual"] < ad["tolerance"], "ADMM did not meet its displayed stop rule"
    assert not math.isclose(second["view"][0][1], second["view"][1][0], rel_tol=0.0, abs_tol=1e-12), (
        "the two checks no longer see bit 2 differently in iteration 2"
    )
    bits = [0 if value >= 0.0 else 1 for value in path[-1]]
    assert (bits[0] ^ bits[1], bits[1] ^ bits[2]) == (0, 0), f"final hard-decision estimate {bits} is not a codeword"


def check_wording_and_structure(html: str) -> None:
    visible = re.sub(r"<script\b.*?</script>", " ", html, flags=re.IGNORECASE | re.DOTALL)
    visible = re.sub(r"<style\b.*?</style>", " ", visible, flags=re.IGNORECASE | re.DOTALL)
    prohibited = re.compile(
        r"L-BFGS|matched[ -]inputs?|input[ -]matched|common inputs|same inputs|"
        r"identical[ -]inputs?|gradient messages?|hard word|hard decision|local replica|"
        r"(?:dual|replica)\s+messages?|AWGN log-likelihood|BPSK over AWGN|"
        r"Constant rule|Sum rule|Constant multiple|Square of a difference|"
        r"\b(?:GD|ADMM)\s+(?:sends|returns|delivers)\b",
        flags=re.IGNORECASE,
    )
    match = prohibited.search(visible) or prohibited.search(html)
    assert match is None, f"prohibited or misleading wording: {match.group(0)!r}"
    required = (
        "Matching beats align the visual comparison; they do not imply equal arithmetic, storage, or computational work.",
        "Fixed graph and channel evidence; the ADMM decoding problem",
        "The ADMM check updates shown for A then B both read the same frozen x and u; A then B is presentation order, not a sequential update.",
        "alternating direction method of multipliers",
        "dashed cards are temporary calculations, not messages",
        "hard-decision estimate",
        "this page places the iteration boundary after the check calculation",
        "constructed teaching variant",
        r"Across the next iteration, ADMM keeps $\mathbf{x}^{(1)}$ and the four entries of $\mathbf{u}^{(1)}$",
        "running sums of disagreement, not messages",
        "standard scaled ADMM with the boundary after the",
        "The ADMM trajectory is generated by the explicit rules on this page",
        "not the retained projected-gradient-descent endpoint",
        "not evidence for the active BP–projected-GD research questions, from which ADMM is deferred",
        "It does not establish error rate, convergence, complexity, or decoder superiority over a code ensemble.",
        "independently recomputed by this artifact’s verifier",
        '"Decoding problem"',
        '"Augmented Lagrangian"',
        '"Replica update"',
        '"Nearest point of the segment"',
        '"Scaled dual update"',
        '"Set the derivative to 0"',
        '"Channel model"',
        '"Expand the square"',
        '"Drop constants"',
        "With BPSK modulation",
        "In an AWGN channel",
        r"does not treat $x_i^2$ as constant inside the box",
        r"Omit $U${uSup}_{${A}\to ${I}}$ from this sum",
        "bit ${I} is preparing a message for check ${A}",
        ".chip.excluded",
        "Bit 2 is speaking to check A.",
        ">Play beat</button>",
        ">Next beat →</button>",
        'const label = tour.on ? "Next step"',
        "function resetCurrentBeat()",
        "getInteractionState",
    )
    lowered = html.lower()
    for phrase in required:
        assert phrase.lower() in lowered, f"required explanation is missing: {phrase!r}"
    for stale in (
        "only check ${rest.join",
        "message comes back to bit",
        'class: "strike"',
        "setTimeout(() => { if (!playing && !frozen && current === 0) play(); }, 900)",
        "function advance()",
    ):
        assert stale not in html, f"stale wording or automatic-advance behavior remains: {stale!r}"
    assert html.count('class="lane ') == 2, "expected exactly two method lanes"
    assert html.count('dot.className = "dot"') == 1, "timeline generator is missing or duplicated"
    assert '<button class="dot"' not in html, "timeline dots must not be duplicated statically"
    assert 'tour.next.className = "tour-next"' in html and "function tourNext()" in html, "tutorial mode is missing"
    assert "function runTourSmoke()" in html, "tutorial interaction smoke test is missing"
    assert "if (!zoomed || smoke) return;" in html, "enlarged tutorial must be click-driven"
    assert sorted(re.findall(r'class="zoom-btn" type="button" data-zoom="(\w+)"', html)) == ["admm", "bp", "poly"], (
        "each of the three panels needs one enlarge button"
    )
    assert '"beat_count": 10' in html
    for asset in (KATEX_JS, KATEX_CSS):
        assert asset in html, f"pinned KaTeX asset with integrity hash is missing: {asset[:60]}..."
    assert html.count('R`\\neq`, "sign")') == 4 and '"=", "sign")' not in html, (
        "both lanes must mark the iteration-2 difference at bit 2 with a not-equal sign"
    )


def dump_dom(
    browser: str,
    url: str,
    virtual_time_budget: int,
    window_size: str = "1910,940",
    extra_args: tuple[str, ...] = (),
) -> str:
    with tempfile.TemporaryDirectory(prefix="bp-admm-state-animation-chrome-") as profile:
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
        "visibility",
        "next-beat-label",
        "beat",
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
        "smoke-beat7-bp-math",
        "smoke-beat7-admm-math",
        "smoke-beat8-admm-math",
        "smoke-beat9-bp-math",
        "smoke-beat9-admm-math",
        "smoke-beat9-poly",
        "smoke-beat10-poly",
    )
    bp = data["bp"]
    ad = data["admm"]
    fixed3 = lambda value: f"{value:.3f}".replace("-", "−")
    assert_in_order(
        snapshots["smoke-beat3-bp-explain"],
        ["Bit 2 is speaking to check A.", "check-to-variable message", "leaves out A’s preceding check-to-variable message"],
        "rendered recipient-exclusion explanation",
    )
    assert_in_order(
        snapshots["smoke-beat3-bp-hover"],
        ["bit 2 is preparing a message for check A", "check-to-variable message", "leave out check A’s preceding check-to-variable message"],
        "rendered recipient-exclusion formula note",
    )
    assert_in_order(
        snapshots["smoke-beat7-bp-math"],
        [signed_fixed(value) for value in bp["posterior1"]],
        "rendered BP posterior",
    )
    nudge = data["objective"]["ell"][1] / (2.0 * ad["rho"])
    assert_in_order(
        snapshots["smoke-beat7-admm-math"],
        [f"{ad['targets1'][0][1]:.6f}", signed_fixed(ad["targets1"][1][0]), signed_fixed(nudge), signed_fixed(ad["x1"][1]),
         *[signed_fixed(value) for value in ad["x1"]]],
        "rendered ADMM x-update at bit 2",
    )
    edge_duals = [ad["u1"][0][0], ad["u1"][0][1], ad["u1"][1][0], ad["u1"][1][1]]
    assert_in_order(
        snapshots["smoke-beat8-admm-math"],
        [*[signed_fixed(value) for value in ad["x1"] + edge_duals], f"{ad['primal1']:.6f}", f"{ad['dual1']:.6f}"],
        "rendered ADMM state across the iteration and its residuals",
    )
    assert_in_order(
        snapshots["smoke-beat9-bp-math"],
        [signed_fixed(bp["q2"][1]), signed_fixed(bp["q2"][2])],
        "rendered recipient-indexed BP Q values",
    )
    assert_in_order(
        snapshots["smoke-beat9-admm-math"],
        ["A sees bit 2", signed_fixed(ad["v2"][0][1]), "B sees bit 2", signed_fixed(ad["v2"][1][0])],
        "rendered per-check views of bit 2",
    )
    assert_in_order(
        snapshots["smoke-beat9-poly"],
        [fixed3(value) for value in ad["x2"]],
        "rendered second ADMM iterate",
    )
    iterations = len(ad["path"]) - 1
    assert_in_order(
        snapshots["smoke-beat10-poly"],
        [f"After {iterations} iterations", "000", "a codeword"],
        "rendered ADMM endpoint in the box",
    )

    # Seek into beat 3. Q_{1->A} is first explained as N(1) \\ A, so its substitution starts later:
    # at 5600 ms the derivations are morphing, at 22400 ms L_1 is flying into Q_{1->A},
    # and at 24000 ms the Q_{1->A} label is travelling along its edge.
    substitution_dom = dump_dom(browser, base_url + "?at=22400#beat=3", 2500)
    assert 'class="katex flying"' in substitution_dom, "no value is being substituted into an equation at beat 3, 22400 ms"
    travel_dom = dump_dom(browser, base_url + "?at=24000#beat=3", 2500)
    assert 'class="chip bp hot travelling' in travel_dom, "no BP message label is travelling along its edge at beat 3, 24000 ms"
    morph_dom = dump_dom(browser, base_url + "?at=5600#beat=3", 2500)
    assert 'class="sparkle"' in morph_dom, "no derivation is sparkling between two steps at beat 3, 5600 ms"
    cue_dom = dump_dom(browser, base_url + "?at=3300#beat=3", 2500)
    cues = re.findall(r'<i class="next-cue"(?: style="([^"]*)")?>', cue_dom)
    assert any("opacity: 0;" not in (style or "") for style in cues), (
        "no next-expression triangle is showing before the first derivation change at beat 3, 3300 ms"
    )

    endpoint_time = 900 + iterations * 700
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
    assert_in_order(endpoint_text, [f"After {iterations} iterations", "000"], "timed ADMM endpoint conclusion")
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
        f"PASS: retained BP/channel-evidence hash, {value_count} embedded values, BP replay, "
        f"ADMM teaching-variant replay, wording gates, browser smoke {browser}."
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, KeyError, ValueError, json.JSONDecodeError, subprocess.TimeoutExpired) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
