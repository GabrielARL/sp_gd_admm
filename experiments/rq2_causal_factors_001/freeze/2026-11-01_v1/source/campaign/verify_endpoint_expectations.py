#!/usr/bin/env python3
"""Re-derive the retained exact endpoint gates for this campaign attempt."""

from __future__ import annotations

import csv
import hashlib
import json
from pathlib import Path
import sys

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - Python 3.10 deployment
    import tomli as tomllib  # type: ignore[no-redef]


HERE = Path(__file__).resolve().parent
REPOSITORY = HERE.parents[3]
RECORD = HERE / "endpoint_expectations.toml"
METHODS = (
    ("gd_native_projected", "native_gd"),
    ("v4_asbuilt_frozen", "v4_asbuilt_frozen"),
    ("bp_exact_sum_product", "native_bp"),
)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def scientific_sha256(value: object) -> str:
    encoded = json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def rows(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def source_path(value: str) -> Path:
    candidate = Path(value)
    return candidate if candidate.is_absolute() else REPOSITORY / candidate


def derive(
    native_rows: list[dict[str, str]],
    v4_rows: list[dict[str, str]],
    frames: list[int],
) -> dict[str, object]:
    lookup: dict[tuple[int, str], dict[str, str]] = {}
    for row in native_rows:
        if float(row["physical_esn0_db"]) != 6.0:
            continue
        frame = int(row["frame"])
        if frame in frames:
            lookup[(frame, row["method"])] = row
    for row in v4_rows:
        frame = int(row["frame"])
        if frame in frames and row["arm"] == "asbuilt__frozen":
            copy = dict(row)
            copy["method"] = "v4_asbuilt_frozen"
            lookup[(frame, copy["method"])] = copy

    required = {(frame, method) for frame in frames for method, _ in METHODS}
    if set(lookup) != required:
        raise RuntimeError(
            "retained rows differ from the exact frame-by-method inventory: "
            f"missing={sorted(required-set(lookup))[:5]}, "
            f"extra={sorted(set(lookup)-required)[:5]}"
        )

    channel_pairs: list[list[object]] = []
    for frame in frames:
        hashes = {lookup[(frame, method)]["clipped_llr_sha256"] for method, _ in METHODS}
        if len(hashes) != 1:
            raise RuntimeError(f"channel LLR identities differ on frame {frame}: {hashes}")
        channel_pairs.append([frame, next(iter(hashes))])

    result: dict[str, object] = {
        "frame_first": frames[0],
        "frame_last": frames[-1],
        "frame_count": len(frames),
        "frame_ids_sha256": scientific_sha256(frames),
        "channel_llrs_sha256": scientific_sha256(channel_pairs),
    }
    for method, prefix in METHODS:
        selected = [lookup[(frame, method)] for frame in frames]
        result[f"{prefix}_successes"] = sum(
            row["transmitted_word_equal"].lower() == "true" for row in selected
        )
        result[f"{prefix}_hard_words_sha256"] = scientific_sha256(
            [[frame, lookup[(frame, method)]["hard_word_sha256"]] for frame in frames]
        )
    return result


def main() -> int:
    with RECORD.open("rb") as handle:
        record = tomllib.load(handle)
    sources = record["retained_sources"]
    for source in sources:
        path = source_path(source["path"])
        actual = sha256_file(path)
        if actual != source["sha256"]:
            raise RuntimeError(
                f"retained source changed: {path}: expected {source['sha256']}, found {actual}"
            )

    stages = {
        "calibration": (
            rows(source_path(sources[0]["path"])),
            rows(source_path(sources[1]["path"])),
        ),
        "attribution": (
            rows(source_path(sources[2]["path"])),
            rows(source_path(sources[3]["path"])),
        ),
    }
    output: dict[str, object] = {}
    for stage, (native_rows, v4_rows) in stages.items():
        expected = dict(record[stage])
        expected_sentinel = expected.pop("sentinel_sha256")
        frames = list(range(expected["frame_first"], expected["frame_last"] + 1))
        derived = derive(native_rows, v4_rows, frames)
        if derived != expected:
            raise RuntimeError(
                f"{stage} expectation mismatch:\nexpected={expected}\nderived={derived}"
            )
        sentinel = scientific_sha256(derived)
        if sentinel != expected_sentinel:
            raise RuntimeError(
                f"{stage} sentinel mismatch: expected {expected_sentinel}, found {sentinel}"
            )
        output[stage] = {**derived, "sentinel_sha256": sentinel}

    print(json.dumps(output, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, KeyError, ValueError, RuntimeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(2)
