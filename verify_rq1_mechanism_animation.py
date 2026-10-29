#!/usr/bin/env python3
"""Verify the RQ1 animation against eligible retained JSON and smoke-test it."""

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
HTML_PATH = ROOT / "rq1_mechanism_animation.html"
MAILBOX_PATH = ROOT / "mailboxes_and_arrows.html"
CORE_BUILDER = ROOT / "experiments/comm_core_story_001/build_core_story_trace.py"
RQ2_CONFIG = ROOT / "experiments/rq2_qbar_awgn_001/config.toml"
ALLOWED_SOURCES = {
    "state_tree": "experiments/rq1_state_002/results/2026-10-28_primary_v3/nonzero_sum_tree__pulse.json",
    "state_cycle": "experiments/rq1_state_002/results/2026-10-28_cycle_confirm_v3/cyclic_four_bit__pulse.json",
    "update_tree": "experiments/rq1_update_001/retained/anchor_v2/result.json",
    "update_cycle": "experiments/rq1_update_cycle_001/retained/confirmation_v1/result.json",
    "endpoint": "experiments/rq1_endpoint_001/results/2026-10-28_endpoint_v3/trace.json",
    "core_gd": "experiments/comm_core_story_001/results/2026-10-28_core_story_v1/core_story_trace.json",
    "rq2_anchor": "experiments/rq2_qbar_awgn_001/results/2026-10-28_anchor_v2/science.json",
    "rq2_transfer": "experiments/rq2_qbar_awgn_001/results/2026-10-28_heldout_parallel_windows_v1/science.json",
}
CORE_BEATS = 13
FULL_BEATS = 16


class EvidenceParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.in_evidence = False
        self.parts: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag == "script" and dict(attrs).get("id") == "rq1-evidence":
            self.in_evidence = True

    def handle_endtag(self, tag: str) -> None:
        if tag == "script" and self.in_evidence:
            self.in_evidence = False

    def handle_data(self, data: str) -> None:
        if self.in_evidence:
            self.parts.append(data)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def pointer(document: Any, expression: str) -> Any:
    current = document
    if expression == "":
        return current
    if not expression.startswith("/"):
        raise ValueError(f"JSON pointer must start with '/': {expression!r}")
    for encoded in expression[1:].split("/"):
        token = encoded.replace("~1", "/").replace("~0", "~")
        current = current[int(token)] if isinstance(current, list) else current[token]
    return current


def extract_evidence(html: str) -> dict[str, Any]:
    parser = EvidenceParser()
    parser.feed(html)
    if not parser.parts:
        raise AssertionError("missing <script id='rq1-evidence'>")
    return json.loads("".join(parser.parts))


def check_science_gates(documents: dict[str, Any]) -> None:
    assert documents["state_tree"]["validation"]["all_passed"] is True
    assert documents["state_cycle"]["validation"]["all_passed"] is True
    assert documents["update_tree"]["run_status"] == "valid"
    assert documents["update_tree"]["validation"]["all_passed"] is True
    assert documents["update_cycle"]["run_status"] == "valid"
    assert documents["update_cycle"]["evidence_eligible"] is True
    assert documents["update_cycle"]["validation"]["all_passed"] is True
    assert documents["endpoint"]["status"] == "valid"
    assert documents["endpoint"]["validation_passed"] is True
    core = documents["core_gd"]
    assert core["status"] == "valid" and core["validation"]["all_passed"] is True
    assert core["source"]["path"] == ALLOWED_SOURCES["endpoint"]
    assert core["source"]["sha256"] == sha256(ROOT / ALLOWED_SOURCES["endpoint"]), "core_gd derives from a different endpoint trace"
    anchor, transfer = documents["rq2_anchor"], documents["rq2_transfer"]
    assert anchor["status"] == "valid" and anchor["validation_passed"] is True
    assert anchor["deterministic_replay"]["passed"] is True
    assert transfer["status"] == "valid_parallel_transfer" and transfer["validation_passed"] is True
    assert transfer["deterministic_replay"]["passed"] is True


def check_core_story(html: str, evidence: dict[str, Any]) -> None:
    """Gates specific to the Core story mode."""
    llr = evidence["values"]["tree_llr"]["value"]
    assert llr == [-math.log(9.0), math.log(1.5), math.log(2.0)], "displayed exact forms of L no longer match"
    assert "(−ln 9, ln 3/2, ln 2)" in html
    config = RQ2_CONFIG.read_text(encoding="utf-8")
    assert re.search(r"^maximum_message_passing_iterations = 80$", config, flags=re.M), "RQ2 cap is no longer 80"
    assert "80 message-passing iterations" in html
    required = (
        "Controlled BP ablation — not GD",
        "awaiting canonical one-thread confirmation",
        "This toy animation does not establish error rate, convergence, complexity, or performance across a code ensemble.",
        "Synchronized beats align the explanation, not their arithmetic.",
        "Jade’s native check-first loop places the boundary after the variable update and carries the four Q values instead",
        "They are computed in place and not sent",
        "retaining a separate variable-to-check message for each neighboring check matters causally within exact sum-product on these frames",
        "remain separate candidates for the native BP–GD performance difference",
    )
    for phrase in required:
        assert phrase in html, f"Core story is missing required wording: {phrase!r}"
    assert "project(x + step · direction)" in html, "native scalar update must add the stored descent direction"
    assert "project(x − step · direction)" not in html, "stale native scalar update sign remains"
    gd = evidence["values"]["core_gd_u1"]["value"]
    fingerprint = evidence["values"]["endpoint_scalar_fingerprint"]["value"]
    expected_direction = [-gradient / curvature for gradient, curvature in zip(gd["gradient"], gd["curvature"])]
    expected_raw = [
        state + gd["accepted_step"] * direction
        for state, direction in zip(gd["x_before"], gd["direction"])
    ]
    expected_projected = [
        min(fingerprint["box_upper"], max(fingerprint["box_lower"], proposal))
        for proposal in expected_raw
    ]
    for observed, expected in zip(gd["direction"], expected_direction):
        assert math.isclose(observed, expected, rel_tol=0.0, abs_tol=1e-15), "stored direction is not -gradient/curvature"
    for observed, expected in zip(gd["raw_proposal"], expected_raw):
        assert math.isclose(observed, expected, rel_tol=0.0, abs_tol=1e-15), "raw proposal is not x + step*direction"
    for observed, expected in zip(gd["projected_proposal"], expected_projected):
        assert math.isclose(observed, expected, rel_tol=0.0, abs_tol=1e-15), "projected proposal does not match box projection"
    message_verbs = re.compile(r"\b(returns|receives|sends|delivers)\s+(the\s+)?(arrows?|g_\{|partial[- ]derivatives?)", re.IGNORECASE)
    match = message_verbs.search(html)
    assert match is None, f"GD partial derivatives described as messages: {match.group(0)!r}"
    completed = subprocess.run([sys.executable, "-I", str(CORE_BUILDER), "--check"], capture_output=True, text=True, timeout=60, check=False)
    assert completed.returncode == 0, f"core story derivation is stale:\n{completed.stderr[-800:]}"


def check_wording(html: str, mailbox_html: str) -> None:
    visible = re.sub(r"<script\b.*?</script>", " ", html, flags=re.IGNORECASE | re.DOTALL)
    visible = re.sub(r"<style\b.*?</style>", " ", visible, flags=re.IGNORECASE | re.DOTALL)
    assert not re.search(r"\bADMM\b", visible, flags=re.IGNORECASE), "ADMM entered the RQ1 animation"
    prohibited = re.compile(
        r"matched[ -]inputs?|input[ -]matched|common inputs|same inputs|identical[ -]inputs?|"
        r"edge transfers?|gradient messages?|diagonal preconditioning|preconditioned step|"
        r"AWGN frames?|AWGN anchor frames?|decoding outcomes?|recipient-specific variable-to-check values?",
        flags=re.IGNORECASE,
    )
    match = prohibited.search(visible) or prohibited.search(html)
    assert match is None, f"ambiguous comparison wording: {match.group(0)!r}"
    assert not re.search(r"\bADMM\b", html, flags=re.IGNORECASE), "ADMM entered the RQ1 animation script text"
    assert "not the native projected gradient descent algorithm" in html
    assert "Not a one-factor comparison" in html
    assert "Animation beats synchronize the explanation only" in html
    assert "State-harness indexing:" in html
    assert "one combined variable-then-check map starts from stored check-to-variable" in html
    assert "Jade native indexing:" in html
    assert "the <i>Q</i> array written by the preceding variable update is carried into the next check update" in html
    assert "That check overwrites <i>U/r</i>; the variable update then consumes <i>U/r</i> and overwrites <i>Q</i>" in html
    assert "The terminal Q array is the value carried to a following check update" in html
    assert "Persistent inter-iteration state: check-to-variable <i>U</i>" not in html
    assert "In this page’s variable-then-check flooding schedule" in mailbox_html
    assert "A check-first implementation can place its iteration boundary elsewhere and carry <i>Q</i>" in mailbox_html
    stale_mailbox_claims = (
        "eight directed-edge messages: four <i>Q</i>, four <i>U</i>",
        "All eight messages stay in their mailboxes",
        "all four mailboxes kept",
        "nothing; a new message replaces the old one on its edge",
    )
    for claim in stale_mailbox_claims:
        assert claim not in mailbox_html, f"stale BP persistence wording remains: {claim!r}"


def browser_smoke(html_path: Path) -> str:
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
    with tempfile.TemporaryDirectory(prefix="rq1-animation-chrome-") as profile:
        command = [
            browser,
            "--headless=new",
            "--no-sandbox",
            "--disable-gpu",
            "--disable-dev-shm-usage",
            "--allow-file-access-from-files",
            f"--user-data-dir={profile}",
            "--virtual-time-budget=2500",
            "--dump-dom",
            html_path.resolve().as_uri() + "?smoke=1",
        ]
        completed = subprocess.run(command, capture_output=True, text=True, timeout=35, check=False)
    if completed.returncode != 0:
        tail = completed.stderr[-1200:]
        raise AssertionError(f"headless browser exited {completed.returncode}:\n{tail}")
    assert 'data-rq1-ready="true"' in completed.stdout, "browser did not finish initialization"
    smoke = re.search(r'data-rq1-smoke="([^"]*)"', completed.stdout)
    assert smoke and smoke.group(1) == "passed", f"animation smoke failed: {smoke.group(1) if smoke else 'no result'}"
    assert f'data-rq1-smoke-full="{FULL_BEATS}"' in completed.stdout, "Full evidence beats did not all render"
    assert f'data-rq1-smoke-core="{CORE_BEATS}"' in completed.stdout, "Core story beats did not all render"
    assert f"Beat 1 of {CORE_BEATS} · Core story" in completed.stdout, "smoke cycle did not return to the first Core story beat"
    return f"passed ({Path(browser).name})"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--skip-browser", action="store_true", help="skip the available headless-browser smoke test")
    args = parser.parse_args()

    html = HTML_PATH.read_text(encoding="utf-8")
    mailbox_html = MAILBOX_PATH.read_text(encoding="utf-8")
    evidence = extract_evidence(html)
    assert evidence["schema"] == "rq1-mechanism-animation/evidence-v2"
    assert set(evidence["sources"]) == set(ALLOWED_SOURCES)

    documents: dict[str, Any] = {}
    for source_id, expected_relative_path in ALLOWED_SOURCES.items():
        descriptor = evidence["sources"][source_id]
        assert descriptor["path"] == expected_relative_path, (
            f"{source_id}: unexpected retained source {descriptor['path']!r}"
        )
        source_path = ROOT / descriptor["path"]
        assert source_path.is_file(), f"{source_id}: missing {source_path}"
        observed_hash = sha256(source_path)
        assert observed_hash == descriptor["sha256"], (
            f"{source_id}: SHA-256 mismatch: {observed_hash} != {descriptor['sha256']}"
        )
        documents[source_id] = json.loads(source_path.read_text(encoding="utf-8"))

    check_science_gates(documents)
    for value_id, descriptor in evidence["values"].items():
        source_id = descriptor["source"]
        assert source_id in documents, f"{value_id}: unknown source {source_id!r}"
        retained = pointer(documents[source_id], descriptor["pointer"])
        assert retained == descriptor["value"], (
            f"{value_id}: embedded value differs from {source_id}{descriptor['pointer']}\n"
            f"embedded={descriptor['value']!r}\nretained={retained!r}"
        )
        occurrences = html.count(f'"{value_id}"')
        assert occurrences >= 2, f"{value_id}: embedded but never selected or rendered"

    check_wording(html, mailbox_html)
    check_core_story(html, evidence)
    browser = "skipped by request" if args.skip_browser else browser_smoke(HTML_PATH)
    print(
        f"PASS: {len(evidence['values'])} scientific values, "
        f"{len(evidence['sources'])} eligible source hashes, wording gates, browser smoke {browser}."
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, KeyError, ValueError, json.JSONDecodeError, subprocess.TimeoutExpired) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
