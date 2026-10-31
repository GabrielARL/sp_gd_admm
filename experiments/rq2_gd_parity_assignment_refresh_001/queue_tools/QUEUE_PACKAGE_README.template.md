# RQ2 parity-assignment x replacement queue

This attempt runs the registered fresh 200-case transfer and, only after a
complete-valid transfer result, the locked 200-case attribution stage.  The
queue is serial and fail closed.  It never signals another scientific unit,
never resumes an interrupted result directory, and never launches a third
scientific pass.

The one-off anchor wrapper sends `TERM` after 7,080 seconds and reserves the
remaining 120 seconds inside the 7,200-second cap for termination.  Transfer
and attribution use their own anchor-derived budget records.  Each record has
the same 120-second termination reserve and may not exceed 36,000 seconds.

All scientific processes run with one Julia thread, one OpenMP thread, and one
BLAS thread under nice level 19 and the idle I/O class.  Both wrappers acquire
the per-user `sp-gd-scientific.lock` and refuse launch if another registered
`sp-gd-*.service` unit is active.  They report the conflict but do not stop it.

Before the anchor, create a new attempt-specific queue directory containing
only its filled `queue.toml`; a locked package cannot exist yet because both
stage budgets derive from the anchor measurement.  Run the wrapper and
read-only checker from the frozen source copy, while pointing them at that
attempt configuration:

```text
RQ2_QUEUE_ROOT=/absolute/path/to/new/queue \
  /absolute/path/to/freeze/source/queue_tools/run_anchor_once.sh
```

This arrangement executes the checksum-bound frozen wrapper and the
`status_report.py` beside it.  It does not execute an unverified copy from the
still-unlocked queue directory.  The queue's `config` and `runner` paths remain
the live authored paths recorded at freeze time; the pre-anchor gate requires
their current SHA-256 values to equal the corresponding freeze records.  The
archived config and runner are evidence copies, not an executable source tree.

After a complete-valid anchor, use the frozen `derive_budget.py` to create both
stage budget records, populate the attempt directory with the exact immutable
files listed in `queue.toml`, and rename this template to `README.md`.  The
governance-tool copies in the attempt directory are retained evidence; they
are never the trusted executables.  Lock and verify through the frozen tools:

```text
python3 /absolute/path/to/freeze/source/queue_tools/lock_queue_package.py \
  --queue-root /absolute/path/to/new/queue
python3 /absolute/path/to/freeze/source/queue_tools/status_report.py \
  verify-queue-launch --queue-root /absolute/path/to/new/queue
```

The lock accepts only the immutable files named by `queue.toml`.  During an
attempt, the only unlisted files allowed are the exact registered queue logs,
job markers, progress files, and lock file.  Any other file, including an
unlisted executable or configuration helper, makes every later gate fail.

`status_report.py status --queue-root ...` is read only.  It reports package
integrity, active registered services, and the retained progress/completion
records without invoking Julia or recalculating an endpoint.

Launch the serial transfer-then-attribution unit with the frozen wrapper and
the attempt directory supplied only as data:

```text
RQ2_QUEUE_ROOT=/absolute/path/to/new/queue \
  /absolute/path/to/freeze/source/queue_tools/run_queue.sh
```

The registered systemd unit must use that frozen `run_queue.sh` as its
`ExecStart` and set `RQ2_QUEUE_ROOT` to the locked attempt directory.  A copied
wrapper or copied checker inside the queue directory is not an authorized
launch path.
