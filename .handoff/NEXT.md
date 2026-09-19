# Where this stands, and what is next

Written at the end of a long session so a fresh one can continue without it. Read this first; it is the
state, not the story. Everything below is either verified in this session or marked as not verified.

## The rule that decided most of today

`ARCHITECTURE.md` §4: **if it can be deterministic, make it so.** Code before hook, hook before test, test
before trigger, and prose only for what none of those can carry. Every failure today was a rule that lived
somewhere nobody reads, or a sentence where a mechanism belonged.

## Verified working

- **The cache and the context.** Instructions are read once per node process (prefix stability), so the
  provider's prompt cache holds: 99–100% warm on steady-state calls, mean prompt ~54k (was 720k), TTFT
  1.5–3.2s (was 26.7s), zero failed calls in the samples. Ledger: `harness_events` in the node's SQLite.
- **The worker pool.** Reads spawn on demand and retire when idle; turns route by session (concurrent across
  sessions, ordered within one). `scripts/test-serve-concurrency.sh` proves both halves.
- **The deploy gate.** `scripts/deploy.sh` refuses a dirty tree, a tree behind `main`, a binary that does not
  answer on a scratch port, a **downgrade** (installed commit not an ancestor of this tree), and a listener
  that is not the pid it recorded. Refusals append to `<install>/deploy.log`. `installed.txt` records commit,
  branch, dirty, both hashes, time, reason, `via`, `source_provenance`.
- **Stream-termination telemetry.** `host.rs` records `termination`, `saw_done_sentinel`, `saw_finish_reason`,
  `saw_usage`, `malformed_events`, `chunks`, `last_delta_kind`, `max_gap_ms`, `last_delta_to_end_ms`,
  `ended_silent`, forwarded into the ledger by `provider.lua`. Three mock-stream tests; one pins the
  discriminator between our parser and the response boundary.
- **The gate is green** (`scripts/test.sh`) and the branch rule is in use: home branches stay current,
  changes live on `change/<name>`, merged and deleted.

## Not verified — do not assume

- **The freshness check.** `build.rs` now declares `lua/core` as a dependency, and the embedded check compares
  embedded text against the file on disk. It has **not** been shown to fail, because inside a gate run the
  rebuild re-embeds and the stale condition cannot be created. Prove it outside the gate: edit a Lua file, run
  the embedded check alone, expect `the embedded core is stale`.
- **The `wa.exe` markers.** `strings` said `WASM_AGENT_IN_TURN` and `WA_UPGRADE_VIA` are absent from the
  binaries while the source contains them — so `strings` through git-bash is not a trustworthy instrument
  here. Test the *behaviour* instead: attempt an upgrade from inside a turn and expect a refusal in 0s.

## Next, with owners

1. **The UI tool-age change** (unstarted, specified in the session it came from). An in-flight tool should
   show its age and the bound — `bash · 42s of 300s` — because "bash" alone cannot answer "is this stuck?".
   Hooks: `addTool()` / `settleTool()` in `ui/app.js`, one shared ticker, `setAge(seconds, bound)` on
   `<wa-tool>`. Needs one server field: `exec_timeout_seconds` in `health_body` (`WASM_AGENT_EXEC_TIMEOUT_SECONDS`,
   default 300). The working-vs-stuck verdict already exists — the liveness indicator reads `/health`'s
   `stalled_ms` — and the run's total elapsed is already shown.
2. **The naming rename** — in wasm's lane, `change/naming-rename`, spec injected. `ARCHITECTURE.md` §6 is the
   contract: run, turn, step, model call, tool call, message. Order: schema+migration in one commit, then Lua,
   Rust, UI, tests, docs. Two tests matter: the migration is idempotent, and no old name survives.
3. **`/new` (thread selection)** — unstarted. The client cannot select a thread: `agent_for` calls
   `agentlib.new(nil, …)` and `ensure_session` reuses the newest. Node protocol first (thread id in the turn
   body; `parse_turn_body` already parses it), then the UI `/` menu. Do not create a session until the first
   message, and refuse a thread id the caller does not own.
4. **Small, found by wasm and not done**: `wa-sentinel`'s `verb_upgrade` never clears `WASM_AGENT_IN_TURN` for
   its child (one `.env_remove`); `deploy.sh`'s `fail()` prints a raw bash error when `deploy.log` cannot be
   created.
5. **The PR flow with `CODEOWNERS`** — the mechanism that keeps two lanes off one file. Two writers on one
   file cost three round trips today. PR per `change/<name>`, ownership named for `deploy.sh`, `upgrade.sh`,
   the context policy in `agent.lua`, and the sentinel.

## Traps that cost real time today

- **A check that observes nothing passes.** Three times: a heartbeat test that passed with the heartbeat
  removed; `/version` tracking placed after the branch that answers it; an embedded-freshness check that
  skipped every file when its input was nil. When a check passes, ask what it observed.
- **A POSIX path handed to a native Windows process is silently unusable.** It made a node serve 404 for `/`
  while `/health` said it was fine, and a window showed "not found" for an afternoon.
- **Never stop the node by image name.** Use `serve.pid` or the port.
- **`~/.wasm-agent/env` has no dot.** `~/.wasm-agent/.env` is not read.
- **Do not deploy from a tree that is behind what is installed.** That is a downgrade, and it silently undid
  three fixes before the gate learned to refuse it.
- **The ledger is the arbiter.** Policy disputes today (a context budget, a compaction trigger) were settled
  by a query, not by argument.

## Start here

`bash scripts/test.sh` for the gate. `/health` for the node. `harness_events` for what actually happened.
`ARCHITECTURE.md` for the rules, `AGENTS.md` for the four an agent must know.
