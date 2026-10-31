# Interrupted canonical held-out launch

- UTC interruption observed: `2026-10-30T13:10:05Z`
- Intended phase: frozen 200-frame `RQ2-CONFIRM-001` held-out confirmation
- Environment: Julia 1.12.6, one Julia thread, one BLAS/OMP thread, GNU gzip 1.10
- Frozen input: `freeze/2026-10-28_v2`
- Anchor handoff: `results/2026-10-28_anchor_v2`
- Exit: external `SIGTERM` (`143`) after approximately ten minutes

The process was interrupted inside `validate_anchor_handoff` while independently
replaying and hashing the sealed anchor. It had not entered the held-out
calculation and wrote no science, frame, endpoint, manifest, completion, or
checksum artifact. This directory is an execution audit record only and
contributes no scientific evidence.

The frozen command, inputs, parameters, and source files were not changed. A
new output directory is required because the registered runner refuses to
overwrite any existing path.
