# RQ2 causal-factor campaign controller

This directory contains campaign-level governance for the two registered
factorial blocks.  It does not implement either scientific block.

The controller runs exactly this fail-closed sequence for Block A, then repeats
the sequence for Block B:

1. calibration on frames 20001--20024, with frozen expected endpoints;
2. fresh anchor on frames 50001--50024;
3. fresh-anchor correctness, deterministic-replay, and endpoint-sentinel
   self-consistency gates;
4. prospective fresh transfer on frames 50025--50224;
5. fresh-transfer correctness, replay, and sentinel self-consistency gates;
6. informed attribution on frames 30001--30200, with frozen expected
   endpoints.

The fresh anchor and transfer do not preregister success counts or hard-word
hashes: those outcomes are prospectively unknown.  They preregister only the
case range and internal gates.  The 107/167/200 native-GD/v4/native-BP counts
belong only to the informed attribution stage.

Calibration and each fresh anchor publish checksum-bound frame-loop and
post-loop timing.  Calibration has the only preregistered conservative cap;
its measurement sets the fresh-anchor budget.  Before either 200-frame stage
starts, the fresh-anchor measurement produces an append-only budget record using
`ceil((seconds/frame/pass * target frames * pass count + post-loop seconds)
* 1.5)`.  That measured value is the TERM timeout, not a fixed six-hour cap;
the controller adds 120 seconds only as TERM-to-KILL grace.

Every scientific command is a token array in `queue.toml`; no command is
evaluated by a shell.  The supported substitutions are `{queue_root}`,
`{freeze}`, `{output}`, `{block}`, `{stage}`, and `{runner_stage}`.  The
campaign names the prospective stages `fresh_anchor` and `fresh_transfer`,
while both scientific runners name their corresponding CLI stages `anchor`
and `transfer`; `{runner_stage}` performs that fixed mapping.  Block A receives
the mapped stage as its positional first argument.  Block B receives
`stage --stage {runner_stage}` and no `--freeze` option.  A command must
reference at least one regular file in the checksum-verified freeze.

Each result must contain `science.json`, `endpoint_gate.toml`,
`COMPLETED.toml`, and `MANIFEST.sha256`.  `COMPLETED.toml` must state that the
primary and deterministic-replay science hashes are equal.  The endpoint gate
is block-specific.  Block A owns the native projected-GD, retained v4
`asbuilt__frozen`, and native exact sum-product sentinels.  Its calibration and
attribution stages compare those values with frozen expectations; the
107/167/200 counts occur only in Block A attribution.  Block B owns only its
native-BP and `full__direct` endpoints.  It must reproduce native exact
sum-product, then cross-check its frame range, frame-ID hash, channel-LLR hash,
and native-BP hard-word digest against the already valid Block A result for the
same stage.  Block B never recomputes GD or v4.  For all fresh results, primary
and replay sentinel digests must equal the canonical digest of their respective
fields.  A fresh-anchor gate failure prevents the prospective 200-frame
transfer from starting.

### Scientific-runner integration contract

The stage written by a runner is the mapped CLI stage: `calibration`,
`anchor`, `transfer`, or `attribution`.  `COMPLETED.toml` supplies
`schema_version`, `experiment_id`, `block`, `stage`, `status`,
`correctness_passed`, `deterministic_replay_passed`, `science_sha256`,
`endpoint_gate_sha256`, `primary_science_sha256`, and
`replay_science_sha256`.  The two replay hashes must be concrete and equal;
the two artifact hashes must match the files on disk.

Every `endpoint_gate.toml` has the common identity and gate fields
`schema_version`, `experiment_id`, `block`, `stage`, `gate_mode`,
`sentinel_self_consistency_passed`, `primary_sentinel_sha256`, and
`replay_sentinel_sha256`, plus:

- Block A: `frame_first`, `frame_last`, `frame_count`, `frame_ids_sha256`,
  `channel_llrs_sha256`, `native_gd_successes`,
  `v4_asbuilt_frozen_successes`, `native_bp_successes`, and the three matching
  `*_hard_words_sha256` fields.
- Block B: `frame_first`, `frame_last`, `frame_count`, `frame_ids_sha256`,
  `channel_llrs_sha256`, `native_bp_successes`,
  `native_bp_hard_words_sha256`, `full_direct_successes`,
  `full_direct_hard_words_sha256`, and `native_bp_full_direct_equal`.

Block B's full-direct endpoint must equal its native-BP endpoint.  The
controller then compares Block B's frame range, frame-ID digest, input-LLR
digest, native-BP success count, and native-BP hard-word digest with the
already verified Block A result for the same stage.

Calibration and anchor results also supply checksum-bound `timing.toml` with
exactly `schema_version`, `experiment_id`, `block`, `stage`, `frame_count`,
`pass_count`, `scientific_frame_loop_seconds`, and `post_loop_seconds`.
`MANIFEST.sha256` covers every immutable result artifact; only
`MANIFEST.sha256`, `progress.toml`, and `phase_log.tsv` are excluded from its
inventory.

## Preparing an attempt

1. Fill a copy of `queue_tools/queue.template.toml`.  Placeholder hashes and
   counts are deliberately rejected.
2. Create a source specification from `freeze/freeze_spec.template.toml` and
   run `python3 freeze/build_freeze.py --spec SPEC --output NEW_FREEZE`.  The
   freeze must contain a passed record based on
   `preflight_validation.template.toml`; its exact digest is registered in
   `queue.toml`.
3. Run `python3 queue_tools/prepare_queue.py --config FILLED_QUEUE_TOML
   --output NEW_QUEUE_DIRECTORY`.
4. Validate without launching:

   ```sh
   python3 NEW_QUEUE_DIRECTORY/campaign_queue.py verify \
     --queue-root NEW_QUEUE_DIRECTORY
   ```

5. Launch one detached unit:

   ```sh
   NEW_QUEUE_DIRECTORY/launch_detached.sh NEW_QUEUE_DIRECTORY
   ```

The queue cannot be resumed.  Any interruption, failed gate, pre-existing
output, or telemetry from an earlier invocation requires a new attempt
directory.  `progress.toml` is a current snapshot; `phase_log.tsv`,
`status_history.tsv`, per-job logs, and `queue.log` are append-only records.

The launcher and controller require a functioning per-user systemd manager.
They reject any other active service matching the configured scientific-unit
pattern and also take the shared `sp-gd-scientific.lock`.  Every scientific
subprocess is run with one thread, niceness 19, and idle I/O priority.

