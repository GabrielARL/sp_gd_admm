# Attempt 2026-11-01_v2

This is the fail-closed harness-repair successor to terminal attempt
`2026-11-01_v1` for `RQ2-CAUSAL-FACTORS-001`.  It is a new full attempt,
not a resume.  It keeps the registered scientific mechanism and protocol
unchanged and permits only the implementation binding repair needed for
Block B to resolve and invoke the dynamically loaded native helper under the
queue's exact Julia runtime flags.

## Why v2 is required

V1 completed all four Block A stages and then failed at the start of Block B
calibration at `2026-11-01T08:55:02Z`.  The fresh Julia process raised
`UndefVarError: _modem_and_code not defined` while Block B tried to call the
helper in the dynamically loaded native module.  This was an implementation
binding failure before a Block B endpoint was calculated or written.
Therefore:

- v1 contains no Block B scientific result;
- no v1 Block B value may be interpreted, pooled, or promoted;
- the v1 freeze, queue, four complete-valid Block A result directories,
  terminal marker, progress record, and log remain immutable; and
- v2 must start from the first registered Block A stage and run the original
  `A -> B` order in a new result root.

Although the v1 Block A artifacts are complete-valid, v2 does not reuse them.
The locked controller checks Block B against Block A artifacts in the same
attempt result root.  Re-running Block A preserves that controller contract,
rebinds all cross-block comparisons to one freeze, and avoids a special
B-only evidence path.

## Unchanged scientific contract

The graph and graph hash, frame sets, seeds, all-zero transmitted word,
6 dB known-unit-gain AWGN channel, LLR convention and clipping, Block A and
Block B arms, objectives, update rules, line search, exact sum-product check
calculation, 30-update budgets, primary/replay passes, endpoints, stage order,
one-thread environment, timing boundaries, statistical rules, and every
endpoint gate remain unchanged from v1.  In particular, each Block B stage
must still pass the registered `cross_block_bp` comparison against its v2
Block A counterpart.

`endpoint_expectations.toml` and `verify_endpoint_expectations.py` are
byte-for-byte copies of v1.  Their retained `attempt_id = "2026-11-01_v1"`
records the origin of those preregistered endpoint expectations; it is not a
request to reuse v1 results.

## Strict repair regression gate

Before any freeze is built, a fresh Julia process must run the complete Block
B test entry point with the same strict flags used by the scientific queue.
That gate has now passed with this command:

```sh
JULIA_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 \
julia --threads=1 --startup-file=no --depwarn=error \
  --project=/home/gabiel/Documents/GitHub/JadeJcade-worktrees/awgn-jade-coral-20261012 \
  experiments/rq2_bp_target_state_update_001/test_rq2_bp_target_state_update_001.jl
```

The 85/85 passing Block B assertions include a 1/1 standalone binding
regression and a 9/9 long-code gate.  The suite exercised the actual dynamic
native-module load from compiled code, resolved and invoked
`_modem_and_code`, and verified the registered graph SHA-256
`94d94376995c6eb9e21a5859dde6354d7233f61634b5dbdc91fd70653f5f6e2d`.
An in-process include alone does not satisfy this regression gate.

The complete Block A suite passed 31/31, the campaign-controller suite passed
7/7, and the retained endpoint verifier passed both registered sentinels.
The command and endpoint-gate contracts were reviewed and remain unchanged.

## Built paths and launch state

- Attempt inputs: `experiments/rq2_causal_factors_001/attempts/2026-11-01_v2`
- Immutable source freeze: `experiments/rq2_causal_factors_001/freeze/2026-11-01_v2`
- Locked queue package: `experiments/rq2_causal_factors_001/queue/2026-11-01_v2`
- Result root: `experiments/rq2_causal_factors_001/results/2026-11-01_v2`
- Detached unit: `sp-gd-rq2-causal-factors-20261101-v2.service`

The source repair, strict regression, complete preflight, freeze-verification,
queue-lock, and prelaunch gates all passed.  The detached unit launched at
`2026-11-01T10:00:07Z` and reruns the complete registered Block A then Block B
sequence.  The durable current status is recorded in the queue package's
`progress.toml`, `status_history.tsv`, and `queue.log`; live result telemetry
is written below the result root.  V1 remains immutable and terminal.
