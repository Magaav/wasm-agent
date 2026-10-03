# Wave owner-clearing safety repair

Scope COMPLETE: unsupported prose/legacy settlement creation and replay are fail-closed. Stale-owner recovery adapter STILL UNSUPPORTED. No trusted exact-session/run/boot/child terminal ownership plus descendant/effect drain API is exposed by this activity inventory (sessions, steering_runs, child_completions, Git registry and corroborating process scan). Terminal transcript and absent process command lines are not drain proof. No new adapter/schema/adjudication was fabricated.

Original refused delivery e15bdc1da3fad149da141a4ed0989c4b892478ff was cherry-picked unchanged as ae115a2. Producer/reviewer trees, transcripts and old refused record remain unchanged. WIP 2d8cde5 remains in history, superseded by the finished safety delta.

Before edits: independent real-heartbeat probe rerun on private data, exit 0; false/null both cleared to OFF while helper heartbeat continued (operation op-1790988818226616-9804-4849). After edits: self-contained owner regression 53 checks covers false/null working helper, refusal/no mutation, valid legacy receipt replay and fresh process reads, changed run/boot, recreated visible holder, observe accuracy, terminal-looking stale claim and unavailable store. Helpers killed through their exact owned handles and exit awaited in finally.

Focused commands (all exit 0):

- node scripts/test-wave-owner-refusal.mjs: 53 checks, 0 skipped
- node scripts/test-wave-owner-mutations.mjs: 3 mutants killed (each exit 1), 0 skipped; unsafe prose persistence, unsafe matching replay, M5 observe-resolvability
- node scripts/test-wave-activity-corners.mjs: 24 checks, private public-entry completed-newest/older-unfinished produce/allocate allowance, named land/admit refusal and all four closing-freeze phases
- node scripts/test-wave-derived-state.mjs: 55 checks
- node scripts/test-wave-activity-fix.mjs: 62 checks; unsupported prose success assertions explicitly replaced by held/refused assertions, not skipped
- node scripts/test-wave-lifecycle.mjs: 44 checks
- node scripts/test-wave-retire.mjs: 20 checks
- CARGO_BUILD_JOBS=2 RUST_TEST_THREADS=2 cargo build --offline --manifest-path rust/Cargo.toml -p wa-host --bin wa: exit 0
- CARGO_BUILD_JOBS=2 RUST_TEST_THREADS=2 node scripts/test-wave-public.mjs rust/target/debug/wa.exe: 23 checks, exit 0, private home and source Lua root; missing application verification correctly blocked

Source-correct candidate binary SHA256: 0094516f76dbe05af604ceb1c60c0d688d4fe730f9454bd9e4588e041cd96023. No installed old binary used. Focused tests: 281 assertions plus 3 mutation kills, no focused skips. Full release gate intentionally not run; independent review/admission/application deploy remain outside this delivery.

Intermediate failures preserved privately: first mutation harness exit 1 because receipt fixture lacked kind and replay mutant survived; fixed fixture now validates readResolutions.ok and mutant goes red. Initial native launch exit 1 before build (wrong default cwd redirect); explicit own cwd build passed. Initial old six-assertion WIP test had wrong observe field; corrected and replaced by self-contained suite. Graph impact showed stale symbol/index evidence and is not a correctness certificate.

Recovery procedure: inspect owning-runtime exact owner/run operation status and await full process-tree settlement, inspect retained resource claims/unknown effects and reconcile through sanctioned operator resource path (docs/CONCURRENCY.md and docs/EXECUTION.md). Preserve original claims and receipts. Missing/legacy identities remain held until a future trusted adapter validates ownership and descendant/effect drain at creation AND replay. No live store/resource/operation-index write, main edit, push, restart or deploy performed.
