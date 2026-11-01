# Exact-map dependency dispatcher

This directory contains the one-shot dependency controller that queues
`RQ2-EXACT-MAP-UPDATE-001` only after the seven-job native-composition
campaign has terminated and passed its retained gates.

The controller is deliberately not an `sp-gd-*` scientific unit.  Its unit is
`rq2-exact-map-update-controller-20261101-v1.service`, so it may wait beside
the current scientific unit without being mistaken for a second scientific
campaign.  While waiting it only executes `systemctl --user show` and reads
`QUEUE_FAILED.toml`.  It does not signal, stop, restart, or resume the
predecessor.

Because the predecessor is a transient `--collect` unit, it may disappear
between polls.  `LoadState=not-found` is accepted only after this controller
has itself observed the predecessor active; an initially missing predecessor
fails closed instead of bypassing the dependency.  A collected unit is only
an inactive candidate—the retained completion, progress, and result gates
below remain mandatory.

After the predecessor becomes inactive, the controller performs these gates
in order:

1. verifies the predecessor queue package, freeze, and archived preflight via
   the predecessor's hash-pinned `campaign_queue.py`;
2. requires valid completion and progress records showing `7/7` and
   `queue_complete`, and validates all seven result directories with the same
   locked controller;
3. verifies the pinned successor manifest and lock, all manifest member
   hashes, the locked successor controller and launcher, the successor's own
   package/prelaunch gates, and absence of every successor job/runtime output;
4. creates `LAUNCH_INTENT.toml`, calls the locked successor
   `launch_detached.sh` exactly once, and observes its service, progress, or a
   valid terminal marker;
5. creates exactly one terminal controller record: `DISPATCHED.toml` after
   confirmed dispatch, or `FAILED.toml` after a fail-closed gate.

`events.tsv` is append-only and fsynced after every row.  A durable launch
intent or terminal record makes every later invocation refuse to run; there
is no retry path.

Run the fake-service test suite with:

```sh
python3 -m unittest -v \
  experiments/rq2_exact_map_update_001/dispatcher/test_dependency_dispatcher.py
```

After the successor freeze and queue have been locked, create the immutable
attempt-specific configuration.  The preparer checks every successor manifest
entry and pins both queue controllers, the successor manifest and lock, and
the successor launcher:

```sh
python3 experiments/rq2_exact_map_update_001/dispatcher/prepare_controller_config.py
```

It refuses to overwrite `controller_2026-11-01_v1.toml`.  Launching that
configuration is intentionally a separate human-approved action:

```sh
experiments/rq2_exact_map_update_001/dispatcher/launch_controller_detached.sh
```

That launcher creates the non-scientific transient unit named above.  Merely
preparing or testing this directory does not launch it.
