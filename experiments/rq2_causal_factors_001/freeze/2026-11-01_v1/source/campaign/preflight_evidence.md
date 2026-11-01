# Preflight evidence

Run on 2026-11-01 before the immutable freeze was built:

- Block A Julia tests: 31 passed, 0 failed.
- Block B Julia tests: 84 passed, 0 failed.
- Campaign controller Python tests: 7 passed, 0 failed.
- Retained endpoint derivation: calibration and attribution source-file hashes,
  frame inventories, channel-LLR identities, success counts, hard-word digests,
  and aggregate sentinel digests all matched `endpoint_expectations.toml`.

No registered calibration, fresh-anchor, fresh-transfer, or attribution stage
was executed by this preflight.
