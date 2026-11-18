# harness-land round 4 — one edge case left (verification of ffaa6c84: land after one small fix)
Same worktree/branch (head 1a7bfaa8). Commit locally; never push. Touch only what this needs.
A protocol deploy (expected_sha set) withdrawn BEFORE the watcher's first intake never gets its terminal return:
record(...,"withdrawn",...) creates ack.json itself with "phase":"withdrawn" (rust/wa-sentinel/src/main.rs ~2109,
deploy_protocol.rs ~53-57), but validated_ack accepts only held/spawned/failed/unknown/verified
(sentinel_return.rs:91), so observe_due bails with ack_identity_or_revision_mismatch, an `unknown` journal is
written but never delivered, and the requesting session waits forever. Fix: accept `withdrawn` in validated_ack
(mapping it to the same terminal outcome observed_phase already uses) or create the ack as `held` when absent
while state says withdrawn - pick the one that keeps a single definition of the phases. Test: queue, withdraw
WITHOUT any intake, run the real pass, assert exactly one terminal return in the immutable slot.
Note: 3 older withdraw tests fail only when WASM_AGENT_PROVENANCE=child is set (a wa call's env); unset it when
running the sentinel suite, and say so in REPORT.md.
