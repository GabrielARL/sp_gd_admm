#!/usr/bin/env python3
"""Build the two RQ2-GD-STATE-USE-001 figures used by the synced deck.

The script reads only the eligible terminal held-out result and refuses to
render if any of its four scientific source files has changed.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.colors import LinearSegmentedColormap
from matplotlib.patches import Rectangle


EXPECTED_SHA256 = {
    "frames.csv": "f3e371887149ab992198a2b4fde832fa6f7522e81fa00bad99dd13d54e6f2df6",
    "aggregate.csv": "93b8cfc089e93a426720bad3d0713b0d27cf17e3015c799694976b3b21be5ad9",
    "iterations.csv": "f38a10e902e98e68939fb79e7a9ab4497b88aff7e7ade3cee219a6c0a1acb6c1",
    "science.json": "2ae5f7f636edbf6753529213993b7301535b23d916f465a3b7e1bf7ee9075a64",
}

INK = "#172033"
MUTED = "#5F6B7A"
GD = "#087D77"
GD_SOFT = "#D7EFEC"
CONTROL = "#A5A29B"
CONTROL_SOFT = "#E7E5E0"
GOLD = "#B85F00"
GOLD_SOFT = "#FFF3D6"
WHITE = "#FFFFFF"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def verify_sources(result_dir: Path) -> None:
    for name, expected in EXPECTED_SHA256.items():
        actual = sha256(result_dir / name)
        if actual != expected:
            raise SystemExit(f"refusing changed source {name}: {actual} != {expected}")
    completion = (result_dir / "COMPLETED.toml").read_text(encoding="utf-8")
    if 'status = "complete_valid"' not in completion:
        raise SystemExit("result is not marked complete_valid")


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def endpoint_record(result_dir: Path) -> dict[str, object]:
    science = json.loads((result_dir / "science.json").read_text(encoding="utf-8"))
    record = science["endpoint_results"]["transmitted_word_equal"]
    aggregate = {
        row["endpoint"]: row
        for row in read_csv(result_dir / "aggregate.csv")
    }["transmitted_word_equal"]
    integer_fields = (
        "pairs",
        "both_success",
        "active_only_success",
        "control_only_success",
        "both_failure",
        "active_successes",
        "control_successes",
    )
    for field in integer_fields:
        if int(aggregate[field]) != int(record[field]):
            raise SystemExit(f"aggregate/science mismatch for {field}")
    return record


def divergence_matrix(result_dir: Path) -> tuple[list[str], list[str], list[list[int]]]:
    paired: dict[tuple[int, int], dict[str, dict[str, str]]] = defaultdict(dict)
    for row in read_csv(result_dir / "iterations.csv"):
        key = (int(row["frame"]), int(row["update"]))
        paired[key][row["arm"]] = row

    fields = [
        ("Scalar state entering", "x_before_sha256"),
        ("Offsets entering", "delta_before_sha256"),
        ("Gradient vector", "gradient_sha256"),
        ("Accepted scalar state", "x_after_sha256"),
        ("Refreshed offsets", "delta_after_sha256"),
    ]
    by_update: dict[int, dict[str, int]] = {}
    for update in range(1, 31):
        pairs = [arms for (frame, current), arms in paired.items() if current == update]
        if len(pairs) != 200 or any(set(arms) != {"active", "control"} for arms in pairs):
            raise SystemExit(f"update {update} does not contain 200 complete pairs")
        by_update[update] = {
            field: sum(
                arms["active"][field] == arms["control"][field]
                for arms in pairs
            )
            for _, field in fields
        }

    # The compact final column is valid only if every update from 3 through 30
    # has the same equality percentage for a displayed field.
    for _, field in fields:
        values = {by_update[update][field] for update in range(3, 31)}
        if len(values) != 1:
            raise SystemExit(f"updates 3--30 are not uniform for {field}: {values}")

    labels = [label for label, _ in fields]
    columns = ["Update 1", "Update 2", "Every update 3--30"]
    matrix = [
        [by_update[1][field], by_update[2][field], by_update[3][field]]
        for _, field in fields
    ]
    return labels, columns, matrix


def save_metadata() -> dict[str, object]:
    fixed = datetime(2000, 1, 1, tzinfo=timezone.utc)
    return {
        "Title": "RQ2-GD-STATE-USE-001 deck figure",
        "Author": "Generated from retained terminal artifacts",
        "Creator": "build_deck_plots.py",
        "CreationDate": fixed,
        "ModDate": fixed,
    }


def plot_divergence(result_dir: Path, output: Path) -> None:
    labels, columns, matrix = divergence_matrix(result_dir)
    cmap = LinearSegmentedColormap.from_list("equality", [GOLD_SOFT, GD_SOFT])
    figure, axis = plt.subplots(figsize=(8.8, 3.5))
    image = axis.imshow(matrix, cmap=cmap, vmin=0, vmax=200, aspect="auto")
    del image
    axis.set_xticks(range(len(columns)), columns, fontsize=11, color=INK)
    axis.set_yticks(range(len(labels)), labels, fontsize=10.5, color=INK)
    axis.tick_params(length=0)
    for row, values in enumerate(matrix):
        for column, value in enumerate(values):
            color = GD if value == 200 else GOLD
            axis.text(
                column,
                row,
                f"{int(value)}/200\nidentical",
                ha="center",
                va="center",
                fontsize=10,
                fontweight="bold",
                color=color,
            )
    for spine in axis.spines.values():
        spine.set_visible(False)
    axis.set_title(
        "Paired cases with exactly equal retained hashes",
        fontsize=12,
        fontweight="bold",
        color=INK,
        pad=12,
    )
    figure.text(
        0.5,
        0.015,
        "At update 2 the entering scalar state and offsets still match; the gradient vector and accepted state do not.",
        ha="center",
        fontsize=9.5,
        color=MUTED,
    )
    figure.subplots_adjust(left=0.27, right=0.98, top=0.83, bottom=0.19)
    figure.savefig(output, metadata=save_metadata(), bbox_inches="tight")
    plt.close(figure)


def plot_recovery(result_dir: Path, output: Path) -> None:
    record = endpoint_record(result_dir)
    pairs = int(record["pairs"])
    active = int(record["active_successes"])
    control = int(record["control_successes"])
    both = int(record["both_success"])
    active_only = int(record["active_only_success"])
    control_only = int(record["control_only_success"])
    neither = int(record["both_failure"])
    interval = record["newcombe_interval"]

    figure = plt.figure(figsize=(10.5, 3.8))
    grid = figure.add_gridspec(1, 2, width_ratios=(0.9, 1.35), wspace=0.34)

    rates = figure.add_subplot(grid[0, 0])
    values = [100.0 * control / pairs, 100.0 * active / pairs]
    bars = rates.bar(
        [0, 1], values, width=0.62, color=[CONTROL, GD], edgecolor=[MUTED, GD], linewidth=1.2
    )
    rates.set_xticks([0, 1], ["Retain,\ndo not use", "Retain\nand use"], fontsize=10.5)
    rates.set_ylabel("Hard decision equals transmitted word", fontsize=10, color=INK)
    rates.set_ylim(0, 100)
    rates.set_yticks([0, 20, 40, 60, 80, 100], ["0%", "20%", "40%", "60%", "80%", "100%"])
    rates.grid(axis="y", color=CONTROL_SOFT, linewidth=0.8)
    rates.set_axisbelow(True)
    rates.spines[["top", "right"]].set_visible(False)
    for bar, count in zip(bars, [control, active]):
        rates.text(
            bar.get_x() + bar.get_width() / 2,
            bar.get_height() + 2.5,
            f"{count}/{pairs}",
            ha="center",
            va="bottom",
            fontsize=11,
            fontweight="bold",
            color=INK,
        )
    rates.text(
        0.5,
        0.04,
        "+29.5 percentage points\n97.5% interval: +22.1 to +36.7",
        ha="center",
        va="bottom",
        transform=rates.transAxes,
        fontsize=9.3,
        color=GOLD,
        fontweight="bold",
        bbox={"boxstyle": "round,pad=0.35", "facecolor": GOLD_SOFT, "edgecolor": GOLD},
    )

    matrix = figure.add_subplot(grid[0, 1])
    matrix.set_xlim(0, 2)
    matrix.set_ylim(0, 2)
    cells = [
        (0, 1, both, GD_SOFT, GD, "Both equal"),
        (1, 1, active_only, GOLD_SOFT, GOLD, "Active only"),
        (0, 0, control_only, CONTROL_SOFT, MUTED, "Control only"),
        (1, 0, neither, "#F2F1ED", MUTED, "Neither equals"),
    ]
    for x, y, count, face, edge, label in cells:
        matrix.add_patch(Rectangle((x, y), 1, 1, facecolor=face, edgecolor=WHITE, linewidth=4))
        matrix.text(x + 0.5, y + 0.60, str(count), ha="center", va="center", fontsize=20, fontweight="bold", color=edge)
        matrix.text(x + 0.5, y + 0.28, label, ha="center", va="center", fontsize=9.2, color=INK)
    matrix.set_xticks([0.5, 1.5], ["Control\nequals", "Control\ndoes not equal"], fontsize=10)
    matrix.set_yticks([0.5, 1.5], ["Active does not equal", "Active equals"], fontsize=10)
    matrix.tick_params(length=0)
    for spine in matrix.spines.values():
        spine.set_visible(False)
    matrix.set_title("Paired equality results", fontsize=12, fontweight="bold", color=INK, pad=10)
    matrix.text(
        1.0,
        -0.34,
        "59 discordant pairs favor retain-and-use; 0 favor control",
        ha="center",
        fontsize=9.5,
        color=MUTED,
    )

    figure.suptitle(
        "Held-out results on 200 locked AWGN cases at 6 dB and 30 updates",
        fontsize=13,
        fontweight="bold",
        color=INK,
        y=1.02,
    )
    figure.savefig(output, metadata=save_metadata(), bbox_inches="tight")
    plt.close(figure)


def main() -> None:
    script_dir = Path(__file__).resolve().parent
    repository = script_dir.parents[1]
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--result",
        type=Path,
        default=script_dir / "results" / "2026-10-31_heldout_v2",
    )
    parser.add_argument("--output", type=Path, default=repository / "figures")
    arguments = parser.parse_args()
    result_dir = arguments.result.resolve()
    output_dir = arguments.output.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    verify_sources(result_dir)
    divergence = output_dir / "rq2_gd_state_use_001_divergence.pdf"
    recovery = output_dir / "rq2_gd_state_use_001_recovery.pdf"
    plot_divergence(result_dir, divergence)
    plot_recovery(result_dir, recovery)
    print(f"wrote {divergence}")
    print(f"wrote {recovery}")


if __name__ == "__main__":
    main()
