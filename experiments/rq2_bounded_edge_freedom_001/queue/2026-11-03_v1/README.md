# Attempt `2026-11-03_v1`

This attempt is the first execution of `RQ2-BOUNDED-EDGE-FREEDOM-001`.
It preserves the terminally failed unbounded predecessor and tests the new
bounded successor under its separately registered experiment ID.

The queue is ordered and fail-closed:

1. verify every queue and freeze checksum, then run the frozen tests;
2. run the anchor, whose runner must reproduce retained Block-A
   `compound__box` on frames `20001:20024` before it evaluates fresh anchor
   frames `61497:61520`;
3. run transfer frames `61521:61720` only if the anchor writes a
   `complete_valid` completion record and a passing, deterministic job gate.

Anchor outcome direction is not an expansion gate. A null, positive, or
negative equality-release contrast may all proceed when the registered
correctness, projection, and replay gates pass. No parameter changes between
anchor and transfer.

The 5,400-second wall budget follows the predecessor's prospective budget.
Its retained timing anchors were 66 seconds for the 24-case, two-pass tied
correctness gate and about 1,878 seconds for the four-arm, 200-case Block-A
campaign. The registered margin covers compilation, the lifted edge state,
finite-difference samples, two scientific passes, hashing, and checkpoint
writing. Runtime is diagnostic and does not enter the causal comparison.

The queue is single-threaded, checksum-bound, non-overwriting, and has no
automatic restart or numerical rescue.

The attempt templates contain a freeze-manifest placeholder. After the freeze
has been built, create the immutable queue with:

```text
python3 experiments/rq2_bounded_edge_freedom_001/queue_tools/prepare_queue.py \
  --source experiments/rq2_bounded_edge_freedom_001/attempts/2026-11-03_v1 \
  --freeze experiments/rq2_bounded_edge_freedom_001/freeze/2026-11-03_v1 \
  --output experiments/rq2_bounded_edge_freedom_001/queue/2026-11-03_v1
```

The preparation step replaces the placeholder in both `queue.toml` and
`run_queue.sh` with the SHA-256 of the built freeze's top-level
`MANIFEST.sha256`. At launch, `run_queue.sh` verifies that outer digest before
it asks the manifest to verify the freeze's internal files. A queue therefore
cannot silently follow a rebuilt or substituted freeze at the same path.

The runtime environment is the original Block-A Julia project at
`/home/gabiel/Documents/GitHub/JadeJcade-worktrees/awgn-jade-coral-20261012`.
Before the tests run, the queue requires its registered commit, a clean tracked
worktree, and the pinned hashes of `Project.toml`, `Manifest.toml`, receiver
core, common core, and projected-GD source. The project copy inside the causal
freeze is retained provenance, not a replacement environment.
