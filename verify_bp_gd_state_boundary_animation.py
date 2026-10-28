#!/usr/bin/env python3
"""Verify the focused BP-versus-projected-GD state-boundary animation."""

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
HTML_PATH = ROOT / "bp_gd_state_boundary_animation.html"
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
    raise AssertionError("native projected-GD fingerprint is missing")


def check_source_and_math(data: dict[str, Any]) -> int:
    assert data["schema"] == "bp-gd-state-boundary-animation/v1"
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

    gd = data["gd"]
    close_vector(gd["ell"], trace["channel_evidence"]["ell_bit0_positive"], "GD ell")
    native = trace["rung_results"][6]
    assert native["card_id"] == "RQ1-ENDPOINT-PG-001"
    first = native["result"]["trace"][0]
    close_vector(gd["x0"], first["x_before"], "GD x0")
    close_vector(gd["gradient"], first["gradient"], "GD gradient")
    close_vector(gd["direction"], first["direction"], "GD direction")
    close_vector(gd["x1"], first["projected_proposal"], "GD projected proposal")
    close(gd["accepted_step"], first["accepted_step"], "GD accepted step")
    close(gd["loss_before"], first["loss_before"], "GD loss before")
    close(gd["loss_after"], first["loss_after"], "GD loss after")
    assert gd["active_projection_coordinates"] == first["active_projection_coordinates"] == []

    fingerprint = native_fingerprint(trace)
    assert fingerprint["schedule"] == "frozen_synchronous_full_gradient"
    assert fingerprint["projection"] == "componentwise_box"
    assert fingerprint["preconditioner"] == "native_curvature_bound"
    assert fingerprint["line_search"] == "native_strict_decrease"
    close(gd["weights"]["channel"], fingerprint["channel_weight"], "channel weight")
    close(gd["weights"]["parity"], fingerprint["parity_weight"], "parity weight")
    close(gd["weights"]["binary"], fingerprint["binary_weight"], "binary weight")

    n = gd["n"]
    x = gd["x0"]
    ell = gd["ell"]
    w_ch = gd["weights"]["channel"]
    w_par = gd["weights"]["parity"]
    w_bin = gd["weights"]["binary"]
    checks = [(0, 1), (1, 2)]
    residuals: list[float] = []
    check_terms = [[0.0, 0.0], [0.0, 0.0]]
    parity = [0.0, 0.0, 0.0]
    for check_index, (left, right) in enumerate(checks):
        residual = 1.0 - x[left] * x[right]
        residuals.append(residual)
        g_left = -(2.0 * w_par / n) * residual * x[right]
        g_right = -(2.0 * w_par / n) * residual * x[left]
        check_terms[check_index] = [g_left, g_right]
        parity[left] += g_left
        parity[right] += g_right
    close(residuals[0], gd["residual"]["A"], "GD residual A")
    close(residuals[1], gd["residual"]["B"], "GD residual B")
    close_vector(check_terms[0], gd["g"]["A"], "GD check A terms")
    close_vector(check_terms[1], gd["g"]["B"], "GD check B terms")

    channel = [-(w_ch / (2.0 * n)) * value for value in ell]
    binary = [(4.0 * w_bin / n) * value * (value * value - 1.0) for value in x]
    gradient = [parity[i] + channel[i] + binary[i] for i in range(3)]
    degrees = [1, 2, 1]
    curvature = [(2.0 * w_par * degree + 8.0 * w_bin) / n for degree in degrees]
    direction = [-gradient[i] / curvature[i] for i in range(3)]
    raw = [x[i] + gd["accepted_step"] * direction[i] for i in range(3)]
    projected = [min(1.0, max(-1.0, value)) for value in raw]
    close_vector(channel, gd["channel_partial"], "GD channel partial")
    close_vector(binary, gd["binary_partial"], "GD binary partial")
    close_vector(gradient, gd["gradient"], "recomputed GD gradient")
    close_vector(curvature, gd["curvature"], "recomputed GD curvature")
    close_vector(direction, gd["direction"], "recomputed GD direction")
    close_vector(projected, gd["x1"], "recomputed GD projected proposal")
    return numeric_count(bp) + numeric_count(gd)


def check_wording_and_structure(html: str) -> None:
    visible = re.sub(r"<script\b.*?</script>", " ", html, flags=re.IGNORECASE | re.DOTALL)
    visible = re.sub(r"<style\b.*?</style>", " ", visible, flags=re.IGNORECASE | re.DOTALL)
    prohibited = re.compile(
        r"\bADMM\b|matched[ -]inputs?|input[ -]matched|common inputs|same inputs|"
        r"identical[ -]inputs?|gradient messages?|hard word|"
        r"\bGD\s+(?:sends|returns|delivers)\b",
        flags=re.IGNORECASE,
    )
    match = prohibited.search(visible) or prohibited.search(html)
    assert match is None, f"prohibited or misleading wording: {match.group(0)!r}"
    required = (
        "Matching beats align the visual comparison; they do not imply equal arithmetic, storage, or computational work.",
        "All GD terms shown for A then B are calculated from the same frozen x before one update; A then B is presentation order, not a sequential GD update.",
        "dashed cards are temporary calculations, not messages",
        "this page places the iteration boundary after the check calculation",
        r"Only $\mathbf{x}^{(1)}$ is independent state needed by the next GD calculation",
        "The key visual at bit 2",
        "What differs is the state represented, indexed, retained, and supplied to the next calculation.",
        "It does not establish error rate, convergence, complexity, or decoder superiority over a code ensemble.",
        "this focused page uses the channel evidence and objective function from the retained projected gradient descent trace",
    )
    lowered = html.lower()
    for phrase in required:
        assert phrase.lower() in lowered, f"required explanation is missing: {phrase!r}"
    assert html.count('class="lane ') == 2, "expected exactly two method lanes"
    assert html.count('dot.className = "dot"') == 1, "timeline generator is missing or duplicated"
    assert '<button class="dot"' not in html, "timeline dots must not be duplicated statically"
    assert '"beat_count": 10' in html
    assert r"Q^{(2)}_{2\to A}" in html
    assert r"Q^{(2)}_{2\to B}" in html
    for asset in (KATEX_JS, KATEX_CSS):
        assert asset in html, f"pinned KaTeX asset with integrity hash is missing: {asset[:60]}..."
    assert 'class="neq">≠' in html
    assert 'class="equal">=' in html


def dump_dom(browser: str, url: str, virtual_time_budget: int, window_size: str = "1910,940") -> str:
    with tempfile.TemporaryDirectory(prefix="bp-gd-state-animation-chrome-") as profile:
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
            "--dump-dom",
            url,
        ]
        completed = subprocess.run(command, capture_output=True, text=True, timeout=45, check=False)
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

    snapshots = extract_element_text(
        smoke_dom,
        "smoke-beat7-bp-math",
        "smoke-beat7-gd-math",
        "smoke-beat9-focus",
    )
    bp = data["bp"]
    gd = data["gd"]
    assert_in_order(
        snapshots["smoke-beat7-bp-math"],
        [signed_fixed(value) for value in bp["posterior1"]],
        "rendered BP posterior",
    )
    assert_in_order(
        snapshots["smoke-beat7-gd-math"],
        [
            signed_fixed(gd["g"]["A"][1]),
            signed_fixed(gd["g"]["B"][0]),
            signed_fixed(gd["channel_partial"][1]),
            signed_fixed(gd["binary_partial"][1]),
            signed_fixed(gd["gradient"][1]),
            signed_fixed(gd["x1"][1]),
        ],
        "rendered GD coordinate update",
    )

    beat9 = snapshots["smoke-beat9-focus"]
    assert_in_order(
        beat9,
        [
            "Q2→A(2)", signed_fixed(bp["q2"][1]), "≠", "Q2→B(2)", signed_fixed(bp["q2"][2]),
            "A reads x2(1)", signed_fixed(gd["x1"][1]), "=", "B reads x2(1)", signed_fixed(gd["x1"][1]),
        ],
        "rendered iteration-2 contrast",
    )
    assert "The key visual at bit 2" in beat9, "iteration-2 contrast heading is missing"

    # Seek into beat 3: at 1250 ms the value of L_1 is flying into Q_{1->A};
    # at 2150 ms the Q_{1->A} label is travelling along its edge.
    substitution_dom = dump_dom(browser, base_url + "?at=1250#beat=3", 2500)
    assert 'class="katex flying"' in substitution_dom, "no value is being substituted into an equation at beat 3, 1250 ms"
    travel_dom = dump_dom(browser, base_url + "?at=2150#beat=3", 2500)
    assert 'class="chip bp hot travelling' in travel_dom, (
        "no BP message label is travelling along its edge at beat 3, 2150 ms"
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
        f"PASS: retained source hash, {value_count} numerical values, BP/GD recomputation, "
        f"wording gates, browser smoke {browser}."
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, KeyError, ValueError, json.JSONDecodeError, subprocess.TimeoutExpired) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
