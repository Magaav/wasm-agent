# chat-stall — a turn must reach the model at once

Branch `change/chat-stall`, base `13247bdb`. All work local; nothing pushed, nothing deployed, no live
fleet node called. Measurements on this node (avell), scratch HOMEs under `/tmp/cs`, a hermetic stub
provider on 127.0.0.1:18899, and peers that never answer on closed local ports.

## What was measured, and what the brief had wrong

**1. The mechanism is real, and it is the *run*, not the boot.** A ledger write lock held by a second
process, taken *after* the turn's `run/start` event, moves the turn's first model call by exactly the
hold. Same turn shape, same stub:

| lock taken | spawn → run/start | run/start → model_call/start |
|---|---|---|
| never | 0.31 s | 0.21 s |
| 0.01 s after run/start, held 10 s | 0.30 s | **10.16 s** |

The host names the waiting statement itself (`WASM_AGENT_SQLITE_SLOW_MS=200`):
`[sql] BEGIN IMMEDIATE: 11982ms` for a 12 s hold. The first write a turn makes after `run/start` is its
user message (`agent.lua:2218 record_turn` → `memory.append_turn`), so the turn waits on whoever
holds the writer lock.

**2. A lock taken *before* the spawn is absorbed by boot, not by the run** — 10 s hold → spawn→run/start
10.26 s, run/start→model 0.20 s. This matters because it is why a naive "hold the lock and time the
turn" measurement shows nothing.

**3. The brief's stated suspect does not hold, as stated.** `stt.owners()` did fan out a probe child per
peer, but a probe child's cost is its **boot**, not a long transaction: measured with `/proc/locks` on a
copy of this node's own 909 MB ledger, a `wa nodes probe` child holds the write lock **158.5 ms** (a
`wa show status` boot: 163.8 ms). Probe children cannot hold 16–54 s.

**4. Facts in the brief that are stale or wrong** (rule 9):
- "refreshes the STT role every ~40 s": it is **30 s** — `CONFIGURE_EVERY = 30`, `lua/core/stt.lua:41`.
- "both stalls had that refresh logged 4-5 s into the turn": **could not be re-measured.** The node's
  own ledger is behind `secret_path_denied` for agent bash (`~/.wasm-agent`), so the join over
  `harness_events` on the live node was not available. Unknown, not confirmed.
- "a stall = some process held a ledger write transaction for 16-54 s": plausible and now **reproduced
  in shape**, but no 16–54 s holder was ever caught on a scratch fleet. The holder remains unidentified.

## What was fixed

**`8f7dbc78` — `stt.owners()` reads the roster, never probes the peers.**
`owners()` needs node ids and nothing else, but it called `nodes.list()` with no options, which starts
one `wa nodes probe <peer>` child per peer (20 s deadline each) to learn a capability set the function
never reads. It now calls `nodes.list({ live_capabilities = false })` — the same words `nodes.find`
already uses. The roster read is still fresh (`invalidate()` still runs on the same call).
Cost measured with `nodes.list({peers=...})` over three unreachable peers: roster-only **121 ms** vs the
live list **493 ms**. **Caveat, and it is the honest one:** that run was a script run, so the fan-out was
refused by `nodes.lua`'s `probe_disabled_script_run` guard and the 493 ms is a refused fan-out plus the
rendezvous read, not three real probe children. The number is a floor, not the live cost.

**`b2b9a9f6` — no child-process call inside a ledger write transaction.**
`subagents.lua` ran `host.subagent("start")` and `host.subagent("continue")` **inside**
`memory.transaction`, so a child admission happened while this node held the ledger write lock: the
transaction could not commit until another process answered, and every other writer waited on it. The
guard's read-modify-write is still its own atomic unit; the admission has its own native lock and its own
idempotency key (`deduplicated` still answers a repeat). The transaction is now closed before the host
call in both places (`lua/core/subagents.lua:615` and `:730`).

## Tests

**`scripts/test-stt-role.lua`** (extended, `8f7dbc78`): the registry stub now records the `opts` each
`nodes.list` call receives, and the test asserts every roster read during a `configure` passes
`live_capabilities = false`, plus that the roster still names every owner. It asserts the **ask**, so it
holds however the roster is answered. On base `13247bdb`: `FAIL roster read 1 asked for a live probe
(opts.live_capabilities is nil)`. Green here (`79 checks`).

**`scripts/test-ledger-transactions.lua`** (new, `b2b9a9f6`): parses every transaction body in the eight
modules that own one (strings, comments and long strings blanked, matching brackets), and fails on
`host.subagent`, `host.http`, `host.http_stream`, `host.operation`, `host.exec`, `host.sleep`,
`nodes.remote_call` or `nodes.probe` **inside** the block. Its own parser is tested against a known-bad
and a known-good snippet, so a blanking bug cannot make it pass silently. On base: **2 FAILs**, at
`lua/core/subagents.lua:604` and `:715` — the exact lines fixed in `b2b9a9f6`. Green here (`197 checks,
24 transaction bodies`).

**Wiring:** both suites discover `scripts/test-*.lua` by glob (`scripts/fast.sh:10`,
`scripts/test.sh`), and neither file is in `scripts/fast-path.exclude` (63 entries, checked), so both
rows run in the fast path and in the gate.

## Before / after distribution (item 5)

50 turns each, same stub, same scratch ledger, `run/start` → `model_call/start` from `harness_events`:

| tree | n | min | p50 | p90 | max | ≥1 s | turn wall mean |
|---|---|---|---|---|---|---|---|
| base `13247bdb` | 50 | 0.194 s | 0.197 s | 0.205 s | 0.212 s | 0 | 0.52 s |
| `change/chat-stall` | 50 | 0.193 s | 0.197 s | 0.204 s | 0.213 s | 0 | 0.52 s |

**Read this honestly: the two distributions are the same, because an idle fleet never contends.** With no
holder, neither tree stalls (matching the brief's own "60 normal turns at 0.29–0.36 s"). The difference
this branch makes is only visible under contention, and that is the table in section 1: the mechanism is
reproduced, and what removes a holder is the two commits above.

## What is NOT done — stated, not glossed

1. **No 16–54 s holder was caught.** The mechanism is reproduced with a synthetic holder; the process
   that actually held the live ledger for 16–54 s on 21/11 was never identified.
2. **The specified guard test is not written.** The brief asked for a test that holds a peer probe "in
   flight" (a stub probe child that sleeps) and asserts a concurrent turn reaches its model call in
   < 1 s. What exists instead is (a) the manual cross-process reproduction in `/tmp/cs/inrun.py`, which is
   a driver, not a suite row, and (b) the source lint. **A bug that crosses processes has no suite-level
   cross-process test here yet** (rule 16), and that is the main gap of this round.
3. **The `stt` fix's live cost is not measured.** The 121 ms vs 493 ms figure was taken with the probe
   fan-out refused; a scratch rendezvous with real unreachable peers would give the honest number.

## Pre-existing failures (not this branch)

Run on base `13247bdb` in a separate worktree, identical output there and here:

- `test-subagent-selection`: `lua/core/orchestrator.lua:10: no such table: orchestration_policy`
- `test-orchestration-routing`: `assertion failed` at line 4
- `test-placed-child-workspace`: `fixture scenario required` (needs an argument)

## Texts to approve

Test output only; no model-facing or operator-facing string changed in the product.

1. `stt.owners: read the roster, never probe the peers` — commit subject (`8f7dbc78`).
2. `ledger: no child-process call inside a write transaction; a lint with teeth` — commit subject (`b2b9a9f6`).
3. `%s:%d holds the ledger write lock across %s - that is a turn waiting on another process's work; take it out of the transaction` — new test FAIL line.
4. `the lint read at least six transaction-owning files (%d)` / `the lint found transaction bodies to inspect (%d)` — new test check lines.
5. `the parser finds a forbidden call inside a transaction when there is one` / `a call AFTER the transaction closes is not reported` — new test self-checks.
6. `this test must run in a scratch WASM_AGENT_HOME, not the node's own: %s` — new test guard line.
7. `ledger transactions ok — %d checks, %d transaction bodies` — new test success line.
8. `roster read %d asked for a live probe (opts.live_capabilities is %s): owners() needs ids, and a probe child per peer is a process per peer holding the ledger write lock for its own boot` — extended stt test FAIL line.
9. `the roster still names every owner, probe-free: %d` / `a configure that names its owners read the roster at all` — extended stt test check lines.
