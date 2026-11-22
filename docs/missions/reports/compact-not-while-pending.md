# compact-not-while-pending - the idle compaction never fires while the session has work

Mission (Victor 21/11, planned with Fable): `/compact` from the idle path is refused, by name, while
the target session has a pending code-mode handle, a pending self-wake or a child run still queued or
running; it is tried again when the last of them settles and the session is idle; an explicit operator
`/compact` is unchanged.

Base 57551064, branch `change/compact-not-while-pending`. Not pushed.

## Premises, re-measured on the base before any code

The orchestrator warned that always-available and session-park landed after the brief was written, and
that the brief's facts come from a reading of the doc at 14963b6. Every premise below was measured on
57551064 (`git show 57551064:<file> | grep -n`), not read from the brief.

| # | premise | measured on 57551064 | verdict |
|---|---|---|---|
| 1 | the idle path is the onStale job on `node.run_finished`, posting `/compact` at 40% | `docs/CONTEXT-COMPACTION.md:5` (`## Idle maintenance (40%)`), `:7` (`onStale` is triggered once by `node.run_finished`); `jobs/on-stale.json:4` (`"topic": "node.run_finished"`); `scripts/on-stale.sh:131` (`compact_body='{"idle":true,"min_percent":40}'`) | true; the body already carried `idle:true` |
| 2 | an IDLE `/compact` is refused by name while the session has a pending handle, a pending wake or a child run | ALREADY LANDED at 6bfd0c55 (an ancestor of the base): `lua/core/server.lua:578` (`idle_pending_work`), `:639` (`if args.idle == true`), `:645` (`error='work_pending'`); the job side at `scripts/on-stale.sh:164` | true - this half needed no code |
| 3 | a pending code-mode handle is `state running/unknown/pending` | `lua/core/codemode_pending.lua:157-160` (`open_record`: running, unknown, pending, or settled-and-unreported); `:197-235` (`session_open`: counts them per session, `unreadable` for a file it cannot decode) | true, and unreported-but-settled handles count too |
| 4 | a pending self-wake is `self_wakes` status `pending` or `dispatching` | `lua/core/selfloop.lua:509-511` (the summary's two counts), `:520` (`total = pending + dispatching`) | true |
| 5 | a child run still queued or running | `lua/core/server.lua:576` (`IDLE_PENDING_CHILD_STATES = queued, running, cancelling`), `lua/core/agent_control.lua:234` (`children_of`) | true, and stricter than the brief (`cancelling` too) |
| 6 | "it is tried again when the last of them settles and the session is idle" | **false as implemented**: only a `/chat` run emits `node.run_finished` (`rust/wa-capabilities/src/serve.rs:2726`, inside the HTTP branch), while a settled handle, a fired self-wake and a returned child all run as a completion (`:2622-2665`, `wa_completion_run`) which emits nothing. After the last work settled, no idle request was made at all | **this was the open half** |
| 7 | the four tests the brief names | `scripts/test-compact-idle-pending.lua` (landed with 6bfd0c55), wired at `scripts/test.sh:1290` | exist, but they drive the `/compact` request only - not the settle |
| 8 | session-park (landed 22/11, after the brief) | `lua/core/session_park.lua`, `selfloop.park`/`hold`/`release` | a parked session must not have its history rewritten either |

The one premise that was wrong is #6: the refusal was complete, the retry was not, and with
always-available nothing retried at all - a session could stay above 40% until the person typed.

## What this branch changes (commit 5e6b9173)

`git show 5e6b9173 --stat`: `lua/core/server.lua`, `rust/wa-capabilities/src/serve.rs`,
`scripts/test-compact-idle-pending.lua`.

- `lua/core/server.lua`: `wa_idle_settled(body)` - the same idle answer, asked at the moment the work
  settles. It refuses `work_pending` (same shape, same names) through the shared `idle_pending_work`,
  refuses `session_parked` (the operator stopped the session: `wa session release` lets the next settle
  compact it), `subagent_compaction_refused`, `session_not_found`, `invalid_settle_request`,
  `session_owner_unknown`, and `session_hold_unknown` when the hold itself cannot be read (unknown is
  not yes). The measurement is the shared `compact_record` the operator path uses, at
  `IDLE_COMPACT_PERCENT = 40`.
- `rust/wa-capabilities/src/serve.rs`: `settle_idle_compaction(&lua, session)` is called once after a
  completion run settles (`scheduler::complete_run`), and only for a body that names a session. It takes
  the maintenance gate `/compact` takes, through `compact_reserve` (shared with `compact_begin`) and
  `compact_try_begin` - one idle compaction at a time across node-threads, and none while a run is
  queued or running node-wide. It does not WAIT for the gate: a settle that loses the race is retried by
  the next settle.
- `scripts/test-compact-idle-pending.lua`: section 6 drives `wa_idle_settled` - a pending handle, a
  pending wake, a running child, all three clear, a park and its release, a subagent, an unknown
  session, a body with no session, and an unreadable pending index (29 new checks; 64 total).

## Checks run, and what they answered

| check | command | result |
|---|---|---|
| the settle cases | `WA_SCRIPT=scripts/test-compact-idle-pending.lua <bin> --db <scratch>` | `compact idle pending ok (64 checks, 0 skipped)` |
| the same test on the BASE Lua | scratch worktree `git worktree add --detach /tmp/cnp-base 57551064`, the test copied in, `WASM_AGENT_LUA_ROOT=/tmp/cnp-base` | fails: `lua error: ...:42: the node's settle retry has an entry point to call` - the test does fail on the code before the change |
| the request path, unchanged | `scripts/test-compact-idle-route.lua` | `compact idle route ok (17 checks, 0 skipped)` |
| the job's own deferral | `scripts/test-on-stale.sh` | `20 checks, 0 failed` / `ok onStale decision` |
| the trigged end to end (real node, stub model, scratch home) | a scratch seed (one master session, one wake due at once, one wake still pending) + `<bin> serve` with `scripts/mock-provider.cjs` on loopback | observed: `[serve] idle compaction after settle: {"error":"work_pending",...,"pending":["1 self-wake(s)"],...}` - the node asked again where the work settled, and refused by name because one wake was still pending |
| the crate's own Rust tests | `cargo test --release -p wa-capabilities --lib` | see the last row of this file (the run is recorded there once it finishes) |
| the land gate's discriminator | `bash scripts/test-discriminates.sh 57551064` | `unrevertable scripts/test-compact-idle-pending.lua - this branch changes rust/, and the Lua rows would run against this tree's binary, not the base's`: it does not judge this branch. Judged by hand above instead, with the base Lua in its own worktree and the same binary |

## What this branch does not claim

- The Rust call site has no unit test of its own. The decision it calls is tested in Lua, and the wiring
  is shown by the recorded scratch-node run above - not by a wired test. A node-booting test for it
  would need the stub provider and the placement tick inside the gate, which this mission did not add.
- The `compacted:true` answer at the settle entry is not exercised (it needs a session above 40% and a
  model call). The admission it would take is the same `compact_record` the operator path uses, which
  `scripts/test-behavior.sh` covers.
- A settle that loses the maintenance gate is skipped, not queued: the next settle tries again. That is
  the design, and it is not measured beyond the fact that `compact_try_begin` returns false.

## Texts to approve (verbatim, new or changed)

1. `server.lua`, the work_pending note (changed tail): `Nothing was summarized; the idle compaction is
   tried again when that work settles.`
2. `server.lua`, `session_parked`: `the session is parked: its history is left as the operator stopped
   it, and the first settle after `wa session release` compacts it`.
3. `server.lua`, `session_owner_unknown`: `the owner of this session is not in the user list, so
   nothing was summarized`.
4. `server.lua`, `session_hold_unknown`: `whether this session is parked could not be read, so nothing
   was summarized: unknown is not clear`.
5. `server.lua`, new codes: `invalid_settle_request`, `session_owner_unknown`, `session_hold_unknown`,
   `session_parked`.
6. `serve.rs`, two node log lines: `[serve] idle compaction after settle: {answer}` and
   `[serve] idle compaction after settle failed: {error}`.
7. `docs/CONTEXT-COMPACTION.md`: the paragraph that starts `Nothing is remembered, so the first idle
   request after the work settles compacts - and that request is made where the work settles. ...`, as
   committed.

## Open items this mission did not take

- `/options` (a listing of toggles, default true, auto-compact among them) - Victor's later request.
- Cache warming: considered (Pi's `cacheWarming`) and dropped by Victor.
