# Preflight evidence: pass

Recorded on 2026-11-01 before any v2 freeze, queue package, result directory,
or scientific stage was created:

- Block A strict Julia suite: 31 passed, 0 failed.
- Block B strict Julia suite: 85 passed, 0 failed.
  - Standalone fresh-process native-binding regression: 1 passed, 0 failed.
  - Long-code gate: 9 passed, 0 failed.
- Campaign-controller Python suite: 7 passed, 0 failed.
- The byte-identical endpoint verifier passed both retained gates:
  calibration sentinel
  `b0248a5d4b9a8c6fbbf2534e04910e49303ec3d03ff3eb6a6f95e3b127fba451`
  and attribution sentinel
  `3fc74849cae50d882e505ac1bac6bf5d2f80850650f2b6c4819b8a2087cf9611`.
- The Block B suite ran with
  `--threads=1 --startup-file=no --depwarn=error` and one BLAS/OMP thread.
  Its standalone regression dynamically loaded the native module from a fresh
  process, resolved and invoked `_modem_and_code` from compiled code, and
  passed the registered long-code graph gate.
- The v1 frozen Block B runner remains
  `a026342c2c903da267db1e3bc7f04f25d58d014b2908d96afe5104943929db93`.
  The patched runner is
  `61df5b2944f21279968f0f0ea5991d5869929468d919fbd367541ee1ea7d464c`,
  and the patched test is
  `45b7c7e2ebb925620549b3043245fe553669dbf59b8b0ee2957a2bb020622e59`.
- The source delta is confined to the registered implementation binding
  repair.  The scientific mechanism and protocol are unchanged.
- Queue commands, stage order, timeouts, one-thread environment, all Block A
  exact/self-consistency gates, and all Block B `cross_block_bp` gates were
  reviewed and remain unchanged.
- The v1 freeze, queue, terminal records, failure log, and four Block A
  manifests re-authenticated against `harness_repair_contract.toml`.

No calibration, fresh-anchor, fresh-transfer, or attribution endpoint was
executed by this preflight.  Freeze construction is now eligible, but no
freeze or queue package has yet been built or locked, and launch remains
unauthorized.
