#!/usr/bin/env python3
"""Bind the v3 held-out wall budget to the completed anchor phase log."""

from __future__ import annotations

import argparse
import csv
import hashlib
import math
from pathlib import Path


EXPECTED_ANCHOR_SCIENCE_SHA256 = (
    "2062fce292d4b41cf93c6dd86afdb6855345b52ff1408d9c89c7318e25b20d46"
)
ANCHOR_CASES = 24
HELDOUT_CASES = 200
PASS_COUNT = 2
SAFETY_FACTOR = 1.5
ABSOLUTE_SAFETY_CAP_SECONDS = 36000
TERMINATION_GRACE_SECONDS = 120


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def quote(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def phase_durations(path: Path) -> dict[tuple[str, str], float]:
    durations: dict[tuple[str, str], float] = {}
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        if reader.fieldnames != ["utc", "pass", "phase", "seconds"]:
            raise RuntimeError(f"unexpected phase-log columns: {reader.fieldnames}")
        for row in reader:
            phase_event = row["phase"]
            if not phase_event.endswith(":end"):
                continue
            phase = phase_event[: -len(":end")]
            key = (row["pass"], phase)
            if key in durations:
                raise RuntimeError(f"duplicate phase end: {key}")
            durations[key] = float(row["seconds"])
    return durations


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--anchor", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()

    anchor = arguments.anchor.resolve()
    output = arguments.output.resolve()
    if output.exists():
        raise RuntimeError(f"refusing to overwrite budget record: {output}")
    science = anchor / "science.json"
    phase_log = anchor / "phase_log.tsv"
    completion = anchor / "COMPLETED.toml"
    for required in (science, phase_log, completion):
        if not required.is_file():
            raise RuntimeError(f"missing completed-anchor artifact: {required}")
    science_hash = sha256_file(science)
    if science_hash != EXPECTED_ANCHOR_SCIENCE_SHA256:
        raise RuntimeError(
            "anchor science hash differs: expected "
            f"{EXPECTED_ANCHOR_SCIENCE_SHA256}, found {science_hash}"
        )

    durations = phase_durations(phase_log)
    frame_keys = [("primary", "frame_loop"), ("replay", "frame_loop")]
    post_keys = [
        (pass_name, phase)
        for pass_name in ("primary", "replay")
        for phase in (
            "statistics",
            "frame_table_hash",
            "iteration_table_hash",
            "gate_hash",
            "pass_completed",
        )
    ] + [("primary", "primary_checkpoint"), ("artifact", "write_result")]
    missing = [key for key in frame_keys + post_keys if key not in durations]
    if missing:
        raise RuntimeError(f"phase log lacks registered end records: {missing}")

    frame_loop_seconds = sum(durations[key] for key in frame_keys)
    seconds_per_frame = frame_loop_seconds / (ANCHOR_CASES * PASS_COUNT)
    projected_frame_seconds = seconds_per_frame * HELDOUT_CASES * PASS_COUNT
    anchor_post_loop_seconds = sum(durations[key] for key in post_keys)
    post_loop_scale = HELDOUT_CASES / ANCHOR_CASES
    projected_post_loop_seconds = anchor_post_loop_seconds * post_loop_scale
    projected_seconds_before_safety = (
        projected_frame_seconds + projected_post_loop_seconds
    )
    budget_seconds = math.ceil(SAFETY_FACTOR * projected_seconds_before_safety)
    if budget_seconds <= TERMINATION_GRACE_SECONDS:
        raise RuntimeError("derived wall budget does not exceed termination grace")
    if budget_seconds > ABSOLUTE_SAFETY_CAP_SECONDS:
        raise RuntimeError(
            f"derived wall budget {budget_seconds} exceeds frozen cap "
            f"{ABSOLUTE_SAFETY_CAP_SECONDS}"
        )
    term_after_seconds = budget_seconds - TERMINATION_GRACE_SECONDS

    lines = [
        'schema_version = "rq2-gd-offset-split-001/budget-v3"',
        'optimization_id = "RQ2-OPTIMIZE-001"',
        f"anchor_science_sha256 = {quote(science_hash)}",
        f"phase_log_sha256 = {quote(sha256_file(phase_log))}",
        f"anchor_cases = {ANCHOR_CASES}",
        f"heldout_cases = {HELDOUT_CASES}",
        f"pass_count = {PASS_COUNT}",
        f"safety_factor = {SAFETY_FACTOR}",
        f"absolute_safety_cap_seconds = {ABSOLUTE_SAFETY_CAP_SECONDS}",
        f"termination_grace_seconds = {TERMINATION_GRACE_SECONDS}",
        f"primary_frame_loop_seconds = {durations[('primary', 'frame_loop')]:.9f}",
        f"replay_frame_loop_seconds = {durations[('replay', 'frame_loop')]:.9f}",
        f"anchor_frame_loop_seconds = {frame_loop_seconds:.9f}",
        f"anchor_seconds_per_frame = {seconds_per_frame:.12f}",
        f"projected_frame_seconds = {projected_frame_seconds:.9f}",
        f"anchor_post_loop_seconds = {anchor_post_loop_seconds:.9f}",
        f"post_loop_scale = {post_loop_scale:.12f}",
        f"projected_post_loop_seconds = {projected_post_loop_seconds:.9f}",
        f"projected_seconds_before_safety = {projected_seconds_before_safety:.9f}",
        f"heldout_wall_budget_seconds = {budget_seconds}",
        f"term_after_seconds = {term_after_seconds}",
        "",
        "[phase_seconds]",
    ]
    for (pass_name, phase), seconds in sorted(durations.items()):
        key = f"{pass_name}__{phase}".replace("-", "_")
        lines.append(f"{key} = {seconds:.9f}")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"anchor_science_sha256={science_hash}")
    print(
        "iteration_table_hash_seconds="
        f"{durations[('primary', 'iteration_table_hash')]:.9f},"
        f"{durations[('replay', 'iteration_table_hash')]:.9f}"
    )
    print(f"projected_heldout_seconds={projected_seconds_before_safety:.9f}")
    print(f"heldout_wall_budget_seconds={budget_seconds}")
    print(f"term_after_seconds={term_after_seconds}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
