# BPGD-RQ2-QBAR-AWGN-001 anchor v1 — invalidated

Status: **invalid harness attempt; never eligible as scientific evidence**.

The run failed while assembling the scientific record, before any frame-level
outcome was retained or exposed.  The decoder calculations had occurred in
memory, but `canonical_json` attempted `String(::Int64)` on the integer
iteration keys in the state-snapshot dictionary while computing
`snapshot_scientific_sha256`.  Julia raised a `MethodError`, and the harness
retained only the invalid error record.

Consequently this directory contains no `frames.csv`, `iterations.csv`,
`aggregate.csv`, `runtime.csv`, or state-snapshot archive.  No parity-validity,
transmitted-word-equality, coded-bit-error, syndrome, stopping-iteration, or
paired endpoint result from v1 may be inspected, reported, or reused.  The
200-frame held-out decoder was not run.

The original sealed v1 files remain byte-for-byte unchanged:

```text
science.json       944b1768cf44119d71a4040517469e4178a6e399e1b9346a589051d8f9d221f1
manifest.toml      f3cd2f932bb757d19bbb57698109cd67a4e5c921f042c5c2621391d00eb183ad
COMPLETED.toml     242b187f2e7e935b3cf004a9720ffa95f7642958b75f99462d2b0bf9a830cd98
MANIFEST.sha256    54d1512c6b61fd30a275a26398093f039ec6c911f20c689a8fc8768f38e6b01a
```

This additive `INVALIDATED.md` postmortem is intentionally not part of the
original v1 checksum manifest.  Before it was added, the original manifest
verified with exact file-set equality.  The immutable input freeze v1 remains
retained separately and unchanged.

The authorized v2 repair changes only canonical serialization of integer
dictionary keys and adds regression/tamper tests.  It does not change the
graph, channel, frames, seeds, exact-SP recurrence, tying intervention,
stopping rule, work policy, endpoints, expansion gate, or held-out inference.
