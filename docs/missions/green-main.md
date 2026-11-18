# Mission change/green-main — the landing gate must be able to pass on avell (critical path)

`wa land`'s gate (scripts/fast.sh + cargo rows + prompt-docs) re-runs a failing check once alone and stops on
gate_failed; it cannot tell a pre-existing failure from a new one. On avell (Arch, x86_64, 16 cores, glibc
2.44, node via mise shims, no vault with the release key) main has 13 pre-existing reds, measured in
~/Work/missions/harness-land/wt/REPORT.md ("fast.sh, once" and round 3/4 sections). Earlier lands ran on the
wiped Windows desktop where most passed, so many are this machine's environment, not the code. Base:
change/harness-land (head 97ef887f). For EACH red: find the real cause, fix the CODE or make the TEST robust to
an honest environment difference (e.g. `LC_ALL=C sort`, an exported CARGO_TARGET_DIR, node found via PATH/mise,
systemd user scope availability) - never skip, delete or weaken a check to make it green; if a check truly
needs a resource this node lacks (e.g. land-signing needs the release key's vault), it must SKIP by name with
the reason, the same way fast.sh already skips components without wasi-sdk, and the gate must treat a named
skip as not-failed only where fast.sh already does so.
The reds: test-codemode-model-boundary, test-host-return-docs, test-orchestration-mode, test-observability,
test-remote-call-shape, test-skill-discovery, test-codemode-native (Lua); wa-sentinel: deploy_visibility a_failing_
deploy_leaves_its_message_in_the_capture, deploy_outcome the_sentinel_spawns_waits_and_reports_a_deploy_end_to_end,
node_script_tests x2 (native node dispatch), role_tests the_watcher_records_its_own_owner...; wa-mesh: the 2 relay
tests; prompt-docs (docs/ENVELOPE.md tool-catalogue stale: regenerate with the repo's own sync script);
fast-binary (CARGO_TARGET_DIR exported); publish-artifacts (locale sort order); land-signing (no vault here).
Done when: `bash scripts/fast.sh --jobs 16` and every cargo row the land gate runs are green (or named skips) on
this node, each change with its before/after quoted in REPORT.md. Commit in small steps; never push.
