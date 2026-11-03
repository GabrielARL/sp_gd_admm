# Sequential campaign dispatcher

This dispatcher runs two independent, preregistered queues in sequence so they
cannot compete for the single scientific lock:

1. `RQ2-EDGE-FREEDOM-001`, the causal equality-relaxation diagnostic; then
2. `DEV-COMPOUND-BOX-TRANSFER-001`, the lower-SNR decoder-development transfer.

A terminal failure in the first queue is retained and reported but does not
erase or suppress the independent second queue. Each queue has a 5,400-second
wall limit; the parent systemd unit has a 14,400-second cap and no restart.

Monitor `progress.toml` and `dispatcher.log` in this directory, then use each
queue's own `progress.toml`, `phase_log.tsv`, and result gates for scientific
status. The dispatcher itself does not interpret outcomes.
