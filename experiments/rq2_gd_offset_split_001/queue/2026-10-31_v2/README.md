# `RQ2-GD-OFFSET-SPLIT-001` cap-amended v2 serial queue

This queue implements the approved prospective amendment `RQ2-AMEND-001` and
launch approval `RQ2-LAUNCH-001`.  It changes one protocol field: the held-out
queue-level wall-clock service budget increases from 18,000 to 36,000 seconds.
The per-arm projected-GD stopping rule remains at most 30 update attempts or
the first line-search stall.

The v1 queue, freeze, valid anchor, failed held-out directory, markers,
journal, and log remain immutable.  V2 is not a resume: it uses new queue,
freeze, anchor, and held-out directories and starts each scientific pass from
its first registered frame.  The v1 replay counter is not a checkpoint, and
its in-memory primary calculation is not evidence.

The five jobs remain serial and fail closed.  Endpoint direction is not a
gate.  The byte-identical Julia runner performs the two registered scientific
passes, `primary` and `replay`, plus the one-per-arm-case timed diagnostic
execution.  Verification jobs never invoke the external `replay` command.

At launch, this queue waits while the already-running
`sp-gd-claude-controls-20261031.service` scientific queue remains active.  It
writes a durable `waiting` status every 60 seconds and starts J01 only after
that service is terminal.  The 1,800- and 36,000-second scientific wall
budgets begin inside J02 and J04 respectively, after this external wait.  This
prevents unrelated machine contention from consuming the amended budget; it
does not change a scientific input, calculation, or endpoint.

## Job order

1. `J01` verifies the amendment whitelist and preserved v1 terminal hashes,
   reruns the focused tests, verifies the hash-locked preflight record, runs
   the preflight probe, creates the v2 freeze, and requires its 224-row input
   table to be byte identical to v1.
2. `J02` reruns the 24-case four-arm anchor against the v2 freeze.  This is a
   provenance rebind, not a new result to pool.
3. `J03` verifies the anchor's embedded deterministic-replay record,
   correctness flags, expansion authorization, complete checksum tree, and
   exact equality of `science.json` to the valid v1 anchor.  It does not
   recalculate the anchor.  Any endpoint direction may proceed when these
   correctness and identity gates pass.
4. `J04` runs the 200-case held-out set using the immutable freeze and the
   correctness-valid anchor handoff.
5. `J05` verifies the held-out embedded deterministic-replay record and
   checksum tree and writes `final_summary.toml`.  It does not perform another
   replay calculation or make a scientific interpretation.

Every job uses one Julia thread, one OMP thread, and one OpenBLAS thread.  The
queue runs one job at a time.  A failed job stops all later jobs and leaves its
partial artifacts intact for diagnosis.  There is no automatic restart,
resume, or retry.  An interrupted attempt is retained.  Any further successor
requires prospective authorization, a new immutable freeze, and new queue and
output directories; it must not delete or overwrite this attempt's artifacts.

`QUEUE_MANIFEST.sha256` hash-locks `queue.toml`, `run_queue.sh`,
`status_report.py`, and this README.  The runner verifies that lock before and
after every job.  At initialization it atomically pins the manifest hash in
the non-overwritable `QUEUE_PACKAGE_LOCK.toml` launch record.  `queue.lock` is
held for the lifetime of the process, so a direct second invocation fails
without changing the first attempt.

## Status contract

The queue writes these durable artifacts:

- `progress.toml`: atomically replaced queue-level state, current job,
  completed-job count, PID, timestamps, exit code, and concise detail.
- `status_history.csv`: append-only, fsync'd history of every queue transition.
- `QUEUE_MANIFEST.sha256`: immutable queue-package checksum lock.
- `QUEUE_PACKAGE_LOCK.toml`: atomic launch record pinning the exact queue
  manifest used for this attempt.
- `queue.lock`: process-lifetime exclusivity lock; its contents are not a
  scientific artifact.
- `jobs/JNN/STARTED.toml`: immutable job-start marker.
- `jobs/JNN/COMPLETED.toml` or `jobs/JNN/FAILED.toml`: immutable terminal job
  marker.  Exactly one terminal marker is expected for every started job.
- `logs/JNN.log`: full stdout and stderr for that job.
- `QUEUE_COMPLETED.toml` or `QUEUE_FAILED.toml`: queue terminal marker.
- `final_summary.toml`: correctness and provenance summary written only after
  both result trees pass their embedded-replay and checksum gates.

During `J02` and `J04`, the scientific runner separately atomically replaces
`progress.toml` inside the active result directory after every completed frame
and distinguishes the `primary` and `replay` passes.  Its final record changes
to `artifact_write` when artifact writing has completed; while serialization,
source archival, and checksum work are still running, it can remain at
`replay/pass_completed`.  In that interval a stale-progress warning with a
healthy queue PID indicates no new durable scientific counter, not by itself a
dead service.  The scientific progress file is excluded from scientific and
checksum hashes.
The queue sends `TERM` 120 seconds before each registered wall budget and uses
that remaining 120 seconds as the termination grace.  `KILL` therefore occurs
no later than the registered 1,800-second anchor or 36,000-second held-out
service budget; the grace is inside, not in addition to, that budget.

`status_report.py show` combines the queue-level and active scientific status:

```bash
python3 experiments/rq2_gd_offset_split_001/queue/2026-10-31_v2/status_report.py show
```

A 15-minute chat report should copy the command's current output.  Recording a
heartbeat locally does not itself deliver a user-visible report, so the agent
must keep the turn open and relay the snapshot every 15 minutes until a
terminal queue marker appears.

## Persistent launch

The machine has a running user-level systemd manager.  Launch exactly once:

```bash
systemd-run --user \
  --unit=sp-gd-rq2-offset-split-v2-20261031 \
  --description='RQ2 GD offset split cap-amended v2 serial queue' \
  --working-directory=/home/gabiel/Documents/GitHub/sp_gd_admm-rq1-gd-state-use-20261030 \
  --setenv=JULIA_NUM_THREADS=1 \
  --setenv=OMP_NUM_THREADS=1 \
  --setenv=OPENBLAS_NUM_THREADS=1 \
  --property=Restart=no \
  --property=Nice=5 \
  --property=StandardOutput=append:/home/gabiel/Documents/GitHub/sp_gd_admm-rq1-gd-state-use-20261030/experiments/rq2_gd_offset_split_001/queue/2026-10-31_v2/queue.log \
  --property=StandardError=append:/home/gabiel/Documents/GitHub/sp_gd_admm-rq1-gd-state-use-20261030/experiments/rq2_gd_offset_split_001/queue/2026-10-31_v2/queue.log \
  /usr/bin/bash \
  /home/gabiel/Documents/GitHub/sp_gd_admm-rq1-gd-state-use-20261030/experiments/rq2_gd_offset_split_001/queue/2026-10-31_v2/run_queue.sh
```

Inspect the service without changing it:

```bash
systemctl --user show sp-gd-rq2-offset-split-v2-20261031.service \
  -p ActiveState -p SubState -p ExecMainPID -p ExecMainStatus \
  -p StateChangeTimestamp
```

The account currently has `Linger=no`: the transient service survives terminal
closure while the desktop login remains active, but it does not survive logout
or reboot.  Suspend pauses the calculation and it resumes after wake.

## Failure and claim boundary

`QUEUE_FAILED.toml`, a job `FAILED.toml`, or a result `progress.toml` with
`status = "failed"` is a terminal diagnostic state, not a scientific result.
Do not delete a failed anchor, retune it in place, or reuse this queue attempt.
There is no automatic retry.  A future successor must retain the interrupted
attempt and receive its own prospective authorization and versioned package.

`final_summary.toml` establishes only that the registered calculations,
embedded replay, and provenance checks completed.  Scientific interpretation
must separately report all four arms, all registered contrasts and signs, and
the tested graph, channel evidence, cases, and work budget.  The experiment
separates two uses of constructed retained offsets in the tested projected
gradient descent calculations; it does not establish BP equivalence or
uniquely explain the full native BP-versus-projected-GD performance difference.
