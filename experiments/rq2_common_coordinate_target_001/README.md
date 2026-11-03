# Common-coordinate objective-calculation rung

This directory contains the design and preimplementation audit for
`RQ2-COMMON-COORDINATE-TARGET-001`.

The proposed control is an exact common-coordinate reproduction of native
projected GD. The proposed treatment keeps its one scalar per bit, tied edge
view, initialization, preconditioner, box,
backtracking, attempt budget, and hard-decision rule, but calculates the
partial derivatives or registered clamp-kink selections of a normalized full
registered-recurrence residual instead of the native compound objective.

The treatment is a constructed gradient arm, not BP. The full recipient-
specific residual is retained before its smooth-region partial derivatives or
registered clamp-kink selections are pulled back to the tied scalar state.
The recurrence is native-exact on the BP-reachable bounded subdomain and uses
the frozen saturated extension elsewhere.

Files:

- `experiment_card.md`: prospective scientific contract and claim boundary;
- `derivation_audit.md`: geometry, normalization, and derivative audit;
- `preimplementation_audit.md`: atomicity, duplicate, and launch-blocker
  audit; and
- `terminology_ledger.txt`: reader-visible vocabulary boundary.

Current status: **documentation only**. There is no runner, configuration,
numeric gate registry, freeze, result, queue, or service. Nothing in this
directory authorizes a scientific launch.
