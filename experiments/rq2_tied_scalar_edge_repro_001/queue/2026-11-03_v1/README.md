# Attempt `2026-11-03_v1`

This attempt runs only the approved tied scalar-to-edge reproduction gate.
It contains no treatment that allows stored values sharing a coded-bit index to
differ and no fresh decoder-performance cases.

The one-frame preflight took approximately 32 seconds after compilation. The
wall estimate is therefore:

```text
32 s/frame * 24 frames * 2 passes * 1.5 = 2304 s (38.4 min)
```

The queue cap is 3600 seconds. Compilation, frozen tests, result writing, and
hashing fit inside the remaining margin. Runtime is diagnostic only.

Execution is fail-closed:

1. verify the checksum-bound source freeze and nested retained manifests;
2. run the frozen unit tests;
3. run the 24 retained frames in a primary pass;
4. checkpoint the primary pass;
5. run an independent deterministic replay;
6. require equal scientific hashes and write completion last.

Any mismatch stops this queue. There is no downstream edge-freedom job.

