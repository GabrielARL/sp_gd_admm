#!/usr/bin/env python3
"""Derive a 200-case wall budget from a valid completed anchor phase log."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import re
from pathlib import Path


POST_LOOP_PHASES = (
    "statistics",
    "frame_table_hash",
    "iteration_table_hash",
    "gate_hash",
    "pass_completed",
)
EXPERIMENT_ID = "RQ2-GD-PARITY-ASSIGNMENT-REFRESH-001"
ANCHOR_CASES = 24
TARGET_CASES = 200
PASS_COUNT = 2
SAFETY_FACTOR = 1.5
ABSOLUTE_CAP_SECONDS = 36000
TERMINATION_GRACE_SECONDS = 120


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def toml_scalar(path: Path, key: str) -> str:
    pattern = re.compile(rf"^{re.escape(key)}\s*=\s*(.+?)\s*$")
    for line in path.read_text(encoding="utf-8").splitlines():
        match = pattern.match(line)
        if match:
            value = match.group(1)
            if value.startswith('"') and value.endswith('"'):
                return value[1:-1]
            return value
    raise RuntimeError(f"missing TOML field {key} in {path}")


def verify_result_inventory(root: Path) -> None:
    manifest = root / "MANIFEST.sha256"
    if not manifest.is_file():
        raise RuntimeError(f"missing checksum manifest: {manifest}")
    listed: dict[str, str] = {}
    for line in manifest.read_text(encoding="utf-8").splitlines():
        if not line:
            continue
        expected, separator, relative = line.partition("  ")
        if not separator or relative in listed:
            raise RuntimeError(f"malformed or duplicate checksum row: {line}")
        listed[relative] = expected
    actual = {
        str(path.relative_to(root))
        for path in root.rglob("*")
        if path.is_file()
        and path.name != "MANIFEST.sha256"
        and path.name != "progress.toml"
        and path.name != "phase_log.tsv"
    }
    if actual != set(listed):
        raise RuntimeError(
            f"result inventory mismatch: extra={sorted(actual-set(listed))}, "
            f"missing={sorted(set(listed)-actual)}"
        )
    for relative, expected in listed.items():
        actual_hash = sha256_file(root / relative)
        if actual_hash != expected:
            raise RuntimeError(f"checksum mismatch for {relative}")
    phase_record = root / "PHASE_LOG.sha256"
    phase_log = root / "phase_log.tsv"
    if "PHASE_LOG.sha256" not in listed or not phase_record.is_file():
        raise RuntimeError("phase-log sidecar is not bound by MANIFEST.sha256")
    rows = phase_record.read_text(encoding="utf-8").splitlines()
    if len(rows) != 1:
        raise RuntimeError("malformed PHASE_LOG.sha256")
    expected, separator, relative = rows[0].partition("  ")
    if (
        not separator
        or relative != "phase_log.tsv"
        or not phase_log.is_file()
        or sha256_file(phase_log) != expected
    ):
        raise RuntimeError("phase_log.tsv does not match PHASE_LOG.sha256")


def phase_durations(path: Path) -> tuple[
    dict[tuple[str, str], float], dict[tuple[str, str, str], int]
]:
    durations: dict[tuple[str, str], float] = {}
    events: dict[tuple[str, str, str], int] = {}
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        if reader.fieldnames != ["utc", "pass", "phase", "seconds"]:
            raise RuntimeError(f"unexpected phase-log columns: {reader.fieldnames}")
        for row in reader:
            phase_event = row["phase"]
            if ":" not in phase_event:
                raise RuntimeError(f"malformed phase event: {phase_event}")
            phase, event = phase_event.rsplit(":", 1)
            event_key = (row["pass"], phase, event)
            events[event_key] = events.get(event_key, 0) + 1
            if event == "error":
                raise RuntimeError(f"anchor phase log contains an error: {event_key}")
            if event != "end":
                continue
            key = (row["pass"], phase)
            if key in durations:
                raise RuntimeError(f"duplicate phase end: {key}")
            durations[key] = float(row["seconds"])
    return durations, events


def quote(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--anchor", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--target-stage", choices=("transfer", "attribution"), required=True)
    arguments = parser.parse_args()

    anchor = arguments.anchor.resolve()
    output = arguments.output.resolve()
    if output.exists():
        raise RuntimeError(f"refusing to overwrite budget record: {output}")
    verify_result_inventory(anchor)

    completion = anchor / "COMPLETED.toml"
    manifest = anchor / "manifest.toml"
    science_path = anchor / "science.json"
    phase_log = anchor / "phase_log.tsv"
    for required in (completion, manifest, science_path, phase_log):
        if not required.is_file():
            raise RuntimeError(f"missing anchor artifact: {required}")
    if toml_scalar(completion, "status") != "complete_valid":
        raise RuntimeError("anchor is not complete_valid")
    if toml_scalar(completion, "experiment_id") != EXPERIMENT_ID:
        raise RuntimeError("anchor completion has the wrong experiment ID")
    if toml_scalar(completion, "stage") != "anchor":
        raise RuntimeError("completion is not an anchor")
    if toml_scalar(completion, "deterministic_replay_passed") != "true":
        raise RuntimeError("anchor deterministic replay did not pass")
    if toml_scalar(completion, "anchor_expansion_authorized") != "true":
        raise RuntimeError("anchor did not authorize expansion")
    if toml_scalar(completion, "science_sha256") != sha256_file(science_path):
        raise RuntimeError("anchor science hash is not bound to completion")
    if toml_scalar(completion, "manifest_sha256") != sha256_file(manifest):
        raise RuntimeError("anchor manifest hash is not bound to completion")

    science = json.loads(science_path.read_text(encoding="utf-8"))
    if (
        science.get("experiment_id") != EXPERIMENT_ID
        or science.get("stage") != "anchor"
        or not science.get("correctness_passed")
        or not science.get("anchor_expansion_authorized")
    ):
        raise RuntimeError("science.json is not a valid anchor record")
    anchor_cases = int(science["frame_count"])
    if anchor_cases != ANCHOR_CASES:
        raise RuntimeError(f"anchor case count changed: {anchor_cases}")
    durations, events = phase_durations(phase_log)
    frame_keys = [("primary", "frame_loop"), ("replay", "frame_loop")]
    post_keys = [
        (pass_name, phase)
        for pass_name in ("primary", "replay")
        for phase in POST_LOOP_PHASES
    ] + [("primary", "primary_checkpoint"), ("artifact", "write_result")]
    post_keys.append(("artifact", "checksum_manifest"))
    missing = [key for key in frame_keys + post_keys if key not in durations]
    if missing:
        raise RuntimeError(f"phase log lacks registered end rows: {missing}")
    malformed_counts = [
        key
        for pass_name, phase in frame_keys + post_keys
        for key in ((pass_name, phase, "start"), (pass_name, phase, "end"))
        if events.get(key, 0) != 1
    ]
    if malformed_counts:
        raise RuntimeError(
            f"required phases do not have exactly one start and end: {malformed_counts}"
        )

    pass_count = PASS_COUNT
    frame_loop_seconds = sum(durations[key] for key in frame_keys)
    seconds_per_case_per_pass = frame_loop_seconds / (anchor_cases * pass_count)
    projected_frame_seconds = (
        seconds_per_case_per_pass * TARGET_CASES * pass_count
    )
    anchor_post_loop_seconds = sum(durations[key] for key in post_keys)
    scale = TARGET_CASES / anchor_cases
    projected_post_loop_seconds = anchor_post_loop_seconds * scale
    projected_before_safety = projected_frame_seconds + projected_post_loop_seconds
    budget = math.ceil(SAFETY_FACTOR * projected_before_safety)
    if budget <= TERMINATION_GRACE_SECONDS:
        raise RuntimeError("derived budget does not exceed termination grace")
    if budget > ABSOLUTE_CAP_SECONDS:
        raise RuntimeError(
            f"derived budget {budget} exceeds cap {ABSOLUTE_CAP_SECONDS}"
        )
    term_after = budget - TERMINATION_GRACE_SECONDS

    lines = [
        'schema_version = "rq2-gd-parity-assignment-refresh-001/budget-v1"',
        f"experiment_id = {quote(EXPERIMENT_ID)}",
        f"target_stage = {quote(arguments.target_stage)}",
        f"anchor_result = {quote(str(anchor))}",
        f"anchor_science_sha256 = {quote(sha256_file(science_path))}",
        f"anchor_completion_sha256 = {quote(sha256_file(completion))}",
        f"anchor_manifest_sha256 = {quote(sha256_file(manifest))}",
        f"anchor_checksum_manifest_sha256 = {quote(sha256_file(anchor / 'MANIFEST.sha256'))}",
        f"phase_log_sha256 = {quote(sha256_file(phase_log))}",
        f"anchor_cases = {anchor_cases}",
        f"target_cases = {TARGET_CASES}",
        f"pass_count = {pass_count}",
        f"safety_factor = {SAFETY_FACTOR}",
        f"absolute_safety_cap_seconds = {ABSOLUTE_CAP_SECONDS}",
        f"termination_grace_seconds = {TERMINATION_GRACE_SECONDS}",
        f"anchor_frame_loop_seconds = {frame_loop_seconds:.9f}",
        f"anchor_seconds_per_case_per_pass = {seconds_per_case_per_pass:.12f}",
        f"projected_frame_seconds = {projected_frame_seconds:.9f}",
        f"anchor_post_loop_seconds = {anchor_post_loop_seconds:.9f}",
        f"post_loop_scale = {scale:.12f}",
        f"projected_post_loop_seconds = {projected_post_loop_seconds:.9f}",
        f"projected_seconds_before_safety = {projected_before_safety:.9f}",
        f"wall_budget_seconds = {budget}",
        f"term_after_seconds = {term_after}",
        "",
        "[phase_seconds]",
    ]
    for (pass_name, phase), seconds in sorted(durations.items()):
        lines.append(f"{pass_name}__{phase} = {seconds:.9f}")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"target_stage={arguments.target_stage}")
    print(f"projected_seconds_before_safety={projected_before_safety:.9f}")
    print(f"wall_budget_seconds={budget}")
    print(f"term_after_seconds={term_after}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
