#!/usr/bin/env python3
"""Pin the exact predecessor/successor queue artifacts into the v1 config."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile

try:
    import tomllib  # type: ignore[attr-defined]
except ModuleNotFoundError:  # pragma: no cover - Python 3.10
    import tomli as tomllib  # type: ignore[no-redef]


EXPERIMENT_ID = "RQ2-EXACT-MAP-UPDATE-001"
QUEUE_ID = "2026-11-01_v1"
DISPATCHER_ID = "2026-11-01_v1"


class PreparationError(RuntimeError):
    pass


def sha256(path: Path) -> str:
    if path.is_symlink() or not path.is_file():
        raise PreparationError(f"required regular file is absent: {path}")
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def quoted(value: Path | str) -> str:
    return json.dumps(str(value), ensure_ascii=True)


def manifest_entries(root: Path, manifest: Path) -> dict[str, str]:
    entries: dict[str, str] = {}
    for raw in manifest.read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", raw)
        if match is None:
            raise PreparationError(f"malformed successor manifest line: {raw!r}")
        digest, relative = match.groups()
        relative_path = Path(relative)
        if relative_path.is_absolute() or ".." in relative_path.parts:
            raise PreparationError(f"unsafe successor manifest path: {relative!r}")
        if relative in entries:
            raise PreparationError(f"duplicate successor manifest path: {relative!r}")
        member = root / relative_path
        observed = sha256(member)
        if digest != observed:
            raise PreparationError(f"manifest hash mismatch for {relative}")
        entries[relative] = digest
    if not entries:
        raise PreparationError("successor manifest is empty")
    return entries


def prepare(repo_root: Path, destination: Path) -> Path:
    repo_root = repo_root.resolve()
    destination = destination.resolve(strict=False)
    if destination.exists():
        raise PreparationError(f"refusing to overwrite controller config: {destination}")

    predecessor = (
        repo_root
        / "experiments/rq2_native_composition_001/queue/2026-11-01_v2"
    )
    successor = repo_root / "experiments/rq2_exact_map_update_001/queue/2026-11-01_v1"
    state = (
        repo_root
        / "experiments/rq2_exact_map_update_001/dispatcher/state/2026-11-01_v1"
    )
    pred_controller = predecessor / "campaign_queue.py"
    succ_controller = successor / "campaign_queue.py"
    succ_manifest = successor / "QUEUE_MANIFEST.sha256"
    succ_lock = successor / "QUEUE_PACKAGE_LOCK.toml"
    succ_launcher = successor / "launch_detached.sh"
    entries = manifest_entries(successor, succ_manifest)
    for required in ("campaign_queue.py", "launch_detached.sh", "queue.toml"):
        if required not in entries:
            raise PreparationError(f"successor manifest does not pin {required}")
    with succ_lock.open("rb") as handle:
        lock = tomllib.load(handle)
    expected_lock = {
        "experiment_id": EXPERIMENT_ID,
        "queue_id": QUEUE_ID,
        "status": "locked",
        "queue_manifest_sha256": sha256(succ_manifest),
    }
    for key, expected in expected_lock.items():
        if lock.get(key) != expected:
            raise PreparationError(
                f"successor queue lock {key} mismatch: {lock.get(key)!r}"
            )

    text = f'''schema_version = "rq2-exact-map-update-001/dependency-dispatcher-v1"
dispatcher_id = "{DISPATCHER_ID}"

[controller]
state_dir = {quoted(state)}
systemctl = "/usr/bin/systemctl"
poll_interval_seconds = 30
max_wait_seconds = 259200
confirmation_timeout_seconds = 120
confirmation_poll_seconds = 2
command_timeout_seconds = 120

[predecessor]
unit_name = "sp-gd-rq2-native-composition-20261101-v2.service"
queue_root = {quoted(predecessor)}
controller_relative_path = "campaign_queue.py"
controller_sha256 = "{sha256(pred_controller)}"
failed_relative_path = "QUEUE_FAILED.toml"
completed_relative_path = "QUEUE_COMPLETED.toml"
progress_relative_path = "progress.toml"

[successor]
unit_name = "sp-gd-rq2-exact-map-update-20261101-v1.service"
queue_root = {quoted(successor)}
controller_relative_path = "campaign_queue.py"
controller_sha256 = "{sha256(succ_controller)}"
manifest_relative_path = "QUEUE_MANIFEST.sha256"
manifest_sha256 = "{sha256(succ_manifest)}"
lock_relative_path = "QUEUE_PACKAGE_LOCK.toml"
lock_sha256 = "{sha256(succ_lock)}"
launch_relative_path = "launch_detached.sh"
launch_sha256 = "{sha256(succ_launcher)}"
launch_arguments = [{quoted(successor)}]
progress_relative_path = "progress.toml"
completed_relative_path = "QUEUE_COMPLETED.toml"
failed_relative_path = "QUEUE_FAILED.toml"
experiment_id = "{EXPERIMENT_ID}"
queue_id = "{QUEUE_ID}"
progress_schema = "rq2-exact-map-update-001/progress-v1"
completion_schema = "rq2-exact-map-update-001/queue-completion-v1"
failure_schema = "rq2-exact-map-update-001/queue-failure-v1"
'''
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{destination.name}.tmp.", dir=destination.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        temporary.chmod(0o444)
        try:
            os.link(temporary, destination)
        except FileExistsError as error:
            raise PreparationError(
                f"refusing to overwrite controller config: {destination}"
            ) from error
        directory_fd = os.open(destination.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if temporary.exists():
            temporary.unlink()
    return destination


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    default_repo = Path(__file__).resolve().parents[3]
    parser.add_argument("--repo-root", type=Path, default=default_repo)
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(__file__).with_name("controller_2026-11-01_v1.toml"),
    )
    args = parser.parse_args()
    print(prepare(args.repo_root, args.output))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (PreparationError, OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(2)
