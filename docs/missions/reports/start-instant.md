# start-instant — a turn's first reply must come at once

Branch `change/start-instant`, base `dc6e29d2`. All work local: nothing pushed, nothing deployed, no
fleet node called. Measurements on this node (avell), scratch HOMEs under `/tmp/sk*`, the tree's own
binary built at `CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-start-instant`.

## The answer in one line

With a second process holding the ledger's WRITE lock for 10 s, a turn's model call started **9.26 s**
after the run began on the base and starts in **0.6 s** here; the transcript is whole, and the reader is
told what the wait is (`waiting for the ledger: another process is writing`).

## What the brief had wrong, or could not be re-measured (rule 9)

- **The live ledger could not be read, by me, from here.** `~/.wasm-agent/memory.db` is refused for every
  agent tool (`lua/core/secret_guard.lua`, `ROOT` entry `.wasm-agent/memory.db`) and a checkout's Lua may
  not be pointed at the operator's ledger either (`lua/core/init.lua`, "refusing on-disk Lua against the
  operator's ledger"). So item 1's "read harness_events around the stall" was **not possible** on this
  node; what I did instead is below, and item 5 exists so the operator can run that query themselves.
- **"the last seven are all 15-21 s: one fixed wait or deadline"** — the *numbers* come from the policy
  this repo already had, not from a holder: `BUSY_MS_DEFAULT = 5_000`, `ATTEMPTS_DEFAULT = 5`,
  `RETRY_MS_DEFAULT = 20_000` (`rust/wa-sqlite/src/lib.rs:38,41,45`). One refused write costs a 5 s
  quantum per attempt and is clamped by the 20 s budget, so 6 s and 15-21 s are 2 and 4 quanta. The
  client's own patience was the "fixed wait".
- **"the 20 s probe deadline (lua/core/stt.lua / nodes.list)"** was already closed on 21/11 by
  `change/chat-stall`: `lua/core/stt.lua:230` reads the roster with `live_capabilities = false`, so no
  probe child is started from the STT refresh. Re-checked, still true, not touched here.
- **"a deploy or a serve restart is one holder, by evidence"** — the journal agrees, and it also shows
  the *gate suite*: every stall window I could examine has a deploy unit, a `wa-serve` "Scheduled restart
  job" or `scripts/fast.sh` starting inside it (table below).

## Item 1 — what ran at the stalls (journal, `journalctl --user`)

| stall (local) | what the journal shows in that minute |
|---|---|
| 20/11 07:51 (6.6 s) | `Started [systemd-run] ... WA_FAST_ROWS= bash scripts/fast.sh` |
| 20/11 17:46 (54.1 s) | four `land-20261120T2045…` gate runs start `scripts/fast.sh` in 17:45:57–17:47:17 |
| 21/11 14:29 (15.2 s) | `wa-deploy-…service` FAILURE + `wa-serve.service: Scheduled restart job, restart counter is at 7` |
| 21/11 15:48 (17.8 s) | `wa-serve … Scheduled restart job, restart counter is at 9`, then `deploy.sh --reason after land255` |
| 21/11 18:24 (15.4 s) | `deploy.sh --reason after land259`, `wa-serve … Scheduled restart job (12)` two seconds later |
| 21/11 21:12 (20.6 s) | `deploy.sh --reason codeact-view …`, `wa-serve … Scheduled restart job (14)` |
| 20/11 06:20, 21/11 06:59, 07:11, 07:35, 17:12 | nothing in the journal for that minute |

**The holder's own identity was not caught on the live ledger** — that needs the ledger read that is
refused, or `/proc/locks` at the moment of the stall. What is caught instead is the mechanism, on a
scratch ledger, with the same binary: chat-stall's reproduction (a second process holds the write lock,
the turn's first model call moves by exactly the hold) plus this mission's guard test, which now fails on
the base with 9.36 s and passes here with 0.6 s.

## What was measured here, and where the wait actually is

- The first write a turn makes is **not** the transcript: on the base, a 10 s hold moved the model call by
  9.26 s while `run_body` itself took 200 ms — the wait was in `steering.begin()` (a `memory.transaction`
  row) *before* the preflight clock even started. The clock now starts at the top of `M:run`
  (`lua/core/agent.lua:1896`) and marks `resources`, `steering_begin`, `provider_pin`, `context_boundary`.
- **`agent.new` writes too** (`INSERT INTO session_presence`, measured 5754 ms inside a hold). A test that
  builds the agent *after* taking the lock measures the constructor, not the turn — the fixture says so in
  its own comment and builds the agent before the rendezvous.
- With the fix in place a held turn still pays **once**: `steering.begin`, 404 ms (the window), and then
  every later preamble writer is refused instantly.

## What was fixed

**`bfa2f776` — the window, the outbox, the measurement.**
- `lua/core/sqlite_busy.lua`: a **start window** (`begin_window`/`end_window`, `M.busy_now`,
  `M.on_wait`). For a run's preamble it bounds the patience of ANY write: the retry deadline moves to
  now+patience, the connection's `busy_timeout` is set to it, and the policy module is told via
  `host.sql_patience` so the host's own 5-attempt loop does not multiply it. The state lives on `_G`
  (`__wa_start_window`) because `dofile` re-runs a module: telemetry and memory each hold their own copy.
- `lua/core/ledger_defer.lua`: a transcript row the ledger refuses is **queued**, not waited on;
  `build_context` carries it into the request, and it is written before the next row of the session (order
  is the transcript). Its queue lives on `_G` for the same reason.
- `lua/core/agent.lua`: the preflight clock covers the whole preamble; `steering.begin` and
  `steering.consume` tolerate a refused row (status line, settlement skipped); `record_turn` defers while
  the preamble is open and flushes first afterwards; at the end of the run the ledger is paid with the
  ordinary patience and what is left is named ("the transcript is N message(s) behind …").
- `host.sql_patience` + `rust/wa-capabilities/src/host.rs`: one number the policy already owned, set for
  a preamble (`attempts=1` inside the window). **It lives in the host crate and not in `wa-sqlite` on
  purpose**: `wa-sqlite` is an input of the `graph` component, and a policy change for the host must not
  move a shipped artifact. Measured: with the change in `wa-sqlite`, `scripts/test-component-pins.sh`
  demanded a new `graph` pin, and a local rebuild cannot produce the pinned bytes (every one of the 11
  pinned components differs from its pin when rebuilt here — the pins are path-dependent by design). With
  the change in the host crate the pin check passes: "11 of 11 pinned component(s) verified".
- `lua/core/stalls.lua` + `wa stalls` (`lua/core/init.lua:625`): item 5, the kept measurement.

**`7775e200` — the override moved to the host crate, and bookkeeping writes are named, never fatal.** `lua/core/envelope.lua` (the envelope cache),
`lua/core/prompt_cache.lua` (via its own status line), `lua/core/provider.lua` (`serving_sql`, the
provider-observation store — including "no such table" when the ledger could not create it),
`lua/core/run_failure.lua`'s path via `record_turn`, and `lua/core/telemetry.lua` (drops at once once the
window is busy, with its line). Each says which record was lost; none of them ends the turn.

**Item 3 (tell the reader).** Emitted from the one place that knows the wait is real — the first refusal:
`waiting for the ledger: deploy` when the deploy marker (`lua/core/deploy_pause.lua`) is present, else
`waiting for the ledger: another process is writing`. One line per run, plus a `ledger`/`wait` telemetry
row (which is itself dropped if the ledger is the thing that is busy, as it should be).

## Tests, and that they fail on the base

- `scripts/test-start-instant.lua` (new) + `scripts/fixtures/start-instant-turn.lua` (new): a whole turn in
  its own process with a stub provider (`host.http_stream`, no HTTP, no model), a second process holding
  the write lock, and **the lock verified, not assumed**: before the turn is released, the driver's own
  `BEGIN IMMEDIATE` with 50 ms of patience must be refused, or the row refuses to score.
- **It fails on the base**: same test, same fixture, worktree of `dc6e29d2`
  (`git worktree add /tmp/si-base dc6e29d2`), installed binary, `WASM_AGENT_LUA_ROOT=/tmp/si-base`:
  `FAIL write lock held 10 s: the model call still starts in under 1 s (9359)` and
  `FAIL the reader is told what it waits for` — 2 FAIL, and the held turn's log says `gap_ms=9359`.
  Here: 12 checks, `start-instant ok`, held `gap_ms=597`.
- Wiring: `scripts/test-start-instant.lua` is picked up by the fast path's `scripts/test-*.lua` glob and
  is not in `scripts/fast-path.exclude` (67 entries, checked), so it runs in `scripts/fast.sh` and the gate.
  It reads the tree's binary from `WA_FAST_BIN` (that is the row's own variable), then `WA_BIN`,
  `WA_TEST_BIN`, `FAST_BIN`, then `PATH`.


## The binary and the Lua are one change (and what a Lua-only deploy does

The measurement needs both halves. With this tree's binary (which has `host.sql_patience`) a 10 s hold
costs a turn 0.60 s; with the installed binary and this Lua only, 3.81 s - still bounded, still whole, but
the host's own five-attempt policy costs one backoff per refused preamble write. `begin_window` chooses
accordingly: it lets the statement wait the window only when the host can make it the whole wait
(commit `bdab9667`). Both numbers are printed by `scripts/test-start-instant.lua` on the binary it is
given, so a row that runs an older binary says so in its own number instead of hiding it.

## Texts to approve (verbatim)

1. `waiting for the ledger: deploy`
2. `waiting for the ledger: another process is writing`
3. `steering is unavailable this turn: a note left now would not be queued`
4. `the transcript is %d message(s) behind: the ledger would not take them (%s)`
5. `the ledger is busy (already waited once this run)` — the reason inside a dropped telemetry line and a
deferred transcript row.
6. `wa stalls` output: `run start -> first model call, last %gh: %d turn(s)`, `  median %s   p90 %s
   over 2 s: %d   over 5 s: %d   worst %s`, `    %s  %8s  %s` (when, gap, the phase the run named).

## What I did not verify, and what is still unknown

- **The live distribution.** The brief's 266 turns / median 0.31 s / p90 0.78 s was not re-measured by me:
  the ledger read is refused to a turn on this node. `wa stalls` prints it on the node that owns the
  ledger; until it is run there, the *live* numbers after a deploy remain unknown.
- **The holder's identity on a real stall.** Named by class from the journal (deploy / serve restart / gate
  suite); no live `/proc/locks` capture, so "which process held the lock at 21:12" is still unknown.
- **The 54.1 s stall of 20/11 17:46** is longer than the 20 s retry budget, so it is not one write: the
  journal shows four gate runs in that minute, i.e. a queue of writers, not a single holder.
- **A deploy is not run here**: the fix reaches the node through the ordinary landing pipeline, and the
  test the brief describes (`wa chat` + "hi" during `wa-sentinel request deploy`) is the operator's.

## Suite state, and one flaky row that is not this change

`bash scripts/fast.sh` (one run, under `flock -o ~/Work/missions/.suite.lock`): **1 of 364 checks failed**,
`scripts/test-land.lua`, killed by the 120 s row watchdog. It is not this branch: the same row passes
standalone in **64 s here and 60 s on the base worktree** (655 checks both), so it sits close to the
watchdog and loses the race under a loaded machine. Named rather than fixed: it is outside this mission,
and the numbers are above so the next reader does not have to re-derive them.

Two earlier failures in the first suite run were mine and are fixed: `provider_availability_store`
(a serving-observation write refused by a held lock) and two cancellation rows that my first, too-broad
`pcall` swallowed - a lock refusal is tolerated now, and nothing else is (measured on the base worktree:
`network outage recovery ok (34 checks)`, `provider connection abort recovery ok (32 checks)`).
