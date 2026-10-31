# `RQ2-GD-OFFSET-SPLIT-001` terminal execution report

## Outcome

The first queued attempt is a **terminal execution failure**, not a scientific
result.  The serial queue stopped in `J04`, the 200-case held-out execution,
with exit code `124`.  Three of five jobs completed; `J05` did not start.

The registered held-out question therefore remains unanswered.  In
particular, this attempt does not establish whether the recovery change in the
earlier compound intervention came from using retained check-specific offsets
in the parity calculation, using them in the projection bounds, or their
interaction.

## Registered calculation

All four constructed projected gradient descent arms retain the same scalar
state and the same check-specific offsets.  The two registered factors
determine whether those retained offsets are read in two places:

| Arm | Parity calculation | Projection bounds |
|---|---|---|
| `objective0__bounds0` | offsets not used | `[-1,1]` |
| `objective1__bounds0` | offsets used | `[-1,1]` |
| `objective0__bounds1` | offsets not used | offset-induced interval |
| `objective1__bounds1` | offsets used | offset-induced interval |

The registered held-out set contains frames `30001:30200` at 6 dB for the
length-10,200 regular `(3,6)` code.  Each arm has at most 30 projected gradient
descent update attempts.  The runner must complete both the `primary` and
deterministic `replay` passes before writing the held-out result tree.

## Terminal timeline

Times below are UTC; China Standard Time is UTC+08:00.

- `02:32:28`: queue started.
- `02:34:34`: `J01` completed the tests, preflight checks, source freeze, and
  input freeze.
- `02:59:54`: `J02` completed the 24-case development anchor.
- `02:59:55`: `J03` completed the anchor replay-record, correctness, and
  checksum gate; `J04` then started.
- `03:00:17.475`: the held-out runner recorded its start.
- `07:57:48.026`: its last progress update recorded the `replay` pass with 124
  of 200 frames complete and three of four arms complete for frame 30125.
- `07:57:56`: `J04` and the queue entered the terminal failed state with exit
  code `124`.

The wall control sent `TERM` after 17,880 seconds, leaving its registered
120-second termination grace inside the 18,000-second service budget.  The
budget control therefore operated as registered; the calculation did not
finish within that budget.

The held-out `progress.toml` still says `status = "running"` because it was the
last atomically written scientific progress record before termination.  The
later immutable `jobs/J04/FAILED.toml` and `QUEUE_FAILED.toml` markers are the
authoritative terminal state.

## Integrity and durable artifacts

Checks repeated after termination found:

- all 4 queue-package checksum entries valid;
- all 43 freeze checksum entries valid; the hashed input table contains all
  224 frozen frame identities;
- the anchor marked `complete_valid`, with correctness, deterministic replay,
  and held-out expansion authorization all true; and
- all 50 anchor checksum entries valid, with scientific SHA-256
  `2062fce292d4b41cf93c6dd86afdb6855345b52ff1408d9c89c7318e25b20d46`.

The durable record includes the locked queue, source and input freeze, complete
anchor result, queue history and logs, the `J04` failure marker, the queue
failure marker, and the last held-out progress counter.  The held-out result
directory contains only `progress.toml`.  It has no `frames.csv`,
`aggregate.csv`, `science.json`, result manifest, checksum manifest, or
completion marker.  The queue has no `QUEUE_COMPLETED.toml` or
`final_summary.toml`, and there is no `J05` start or terminal marker.

The replay progress implies that the primary in-memory calculation returned:
the runner starts `replay` only after `primary` returns.  However, the runner
writes the result tree only after both passes complete.  The primary endpoint
arrays and the unfinished replay arrays were therefore not serialized and are
not recoverable from the progress counter.  That counter is not a resume
checkpoint.

## Scientific claim boundary

No held-out four-arm endpoint, contrast, interval, or deterministic scientific
hash was published.  The development anchor authorized the held-out run on
correctness and provenance; it is not a substitute for the preregistered
200-case result.  Partial in-memory computation must not be reported as
decoding-performance evidence.

Consequently, this attempt supplies no causal conclusion about using offsets
in the parity calculation, using them in the projection bounds, or the
interaction between those two uses.  It also supplies no new conclusion about
the wider performance difference between BP and projected gradient descent.

## Runtime diagnostic, not mechanism evidence

The termination log reports 210,954,672,931 allocations and 112,061 garbage
collections.  At termination, the stack was in garbage collection called from
the bounded-mean projection, retained-offset construction, and projected
gradient descent arm calculation.  This is evidence of substantial allocation
pressure during the process and a concrete target for implementation
diagnosis.

The terminal stack is one interrupted instant, and the log does not provide
phase-resolved timing for all computation between the primary and replay
passes.  It therefore does not show that the bounded-mean projection, retained-
offset construction, garbage collection, or any single function was the sole
cause of the elapsed time.  These runtime observations do not answer the
registered causal decoding question.

## Relaunch and amendment boundary

There is no automatic restart or resume.  The failed attempt and its artifacts
must be preserved.  Under the existing registration, a manual relaunch must
use the immutable frozen command with a new queue-attempt directory and a new
held-out output directory.  That literal relaunch retains the 18,000-second
budget; the failed run provides no evidence that the unchanged calculation
will finish within it.

Either practical recovery path requires explicit approval before any files are
amended or any computation is launched:

1. **Cap-only protocol amendment.** Register a new version with a longer
   held-out wall budget, such as 10 hours, while keeping the scientific cases,
   four arm definitions, and calculation source unchanged.  Use new attempt
   and output directories.  Because the work budget and stopping rule change,
   report this as a prospective amendment, not as a relaunch under the
   original registration.
2. **Implementation optimization with equivalence proof.** Reduce allocation
   in the retained-offset construction or related kernels, then require the
   focused tests, bit-for-bit anchor equivalence, preflight checks, and a fresh
   source freeze before a new held-out attempt.  Because the source hash
   changes, this is a new implementation version even if its verified
   scientific calculation is equivalent.

No recovery option has been authorized or launched by this report.

## Subsequent authorization: `RQ2-AMEND-001`

After this terminal report was written, the user approved the prospective
wall-clock-budget amendment `RQ2-AMEND-001` and its launch as
`RQ2-LAUNCH-001`.  This later authorization does not alter any v1 fact above.

The v2 successor changes one protocol field: the held-out queue-level
wall-clock service budget increases from 18,000 to 36,000 seconds.  The queue
sends `TERM` after 35,880 seconds and reserves 120 seconds inside that budget
for termination.  The per-arm projected-GD stopping rule remains at most 30
update attempts or the first line-search stall.  The scientific runner, graph,
cases, seeds, four arms, retained-offset construction, calculations, endpoints,
inference, one-thread environment, and two scientific passes remain unchanged.

V2 uses `freeze/2026-10-31_v2`, `results/2026-10-31_anchor_v2`,
`results/2026-10-31_heldout_v2`, and `queue/2026-10-31_v2`.  It does not resume
or read the v1 held-out journal as a checkpoint.  Its freeze must reproduce the
v1 224-row input table byte for byte, and its new anchor must reproduce the v1
anchor science file exactly before held-out execution.  Approval and launch do
not create causal evidence; the registered question remains unanswered until
the held-out result and all gates complete.

## Evidence record

- [Queue terminal marker](queue/2026-10-31_v1/QUEUE_FAILED.toml)
- [`J04` terminal marker](queue/2026-10-31_v1/jobs/J04/FAILED.toml)
- [Queue transition history](queue/2026-10-31_v1/status_history.csv)
- [`J04` termination log](queue/2026-10-31_v1/logs/J04.log)
- [Last held-out progress record](results/2026-10-31_heldout_v1/progress.toml)
- [Anchor completion record](results/2026-10-31_anchor_v1/COMPLETED.toml)
- [Registered experiment card](experiment_card.md)
