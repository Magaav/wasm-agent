# session-park — a session whose mission was stopped must stay stopped

Branch `change/session-park`, base `12fd4c12`. All work local: nothing pushed, nothing deployed, no fleet
node called, no live ledger opened. Builds and tests on this node (avell), scratch HOMEs under `/tmp`.

## The answer in one line

`wa session park <id>` (or `--mission <name>`) stops a session's schedule and its CLI resume until
`wa session release <id>`: parked, the node's tick dispatches none of that session's wakes and counts
them **held**, the wakes keep their id, time, reason and prompt, and `wa chat --resume`/`--continue`
refuse by name with the release command. Measured across processes: parked -> tick `dispatched=0`,
`held=2`, no new message; released -> the same wake runs, `runs=1` on two consecutive ticks.

## What the brief had wrong, or could not be re-measured (rule 9)

- **"196 messages at the stop, 263 an hour later" was NOT re-measured by me.** That count is in
  `~/.wasm-agent/memory.db`, which is refused to every agent tool (`lua/core/secret_guard.lua`, the
  `.wasm-agent/memory.db` root entry) and a checkout's Lua may not be pointed at the operator's ledger
  (`lua/core/init.lua`, "refusing on-disk Lua against the operator's ledger"). I used the numbers as
  given; everything below was measured on scratch ledgers under `/tmp`.
- **"Each local install wrote a 'deploy pending: resume after the node swap' wake"** — confirmed as the
  mechanism, not as the live event: `M.RESUME_REASON` is exactly that string
  (`lua/core/deploy_pause.lua:32`), and the node's tick releases and then dispatches those rows
  (`lua/core/selfloop.lua:1321`, `deploy_pause.release_due`). That is the row the new test schedules.
- **"There is no verb to park or cancel one session"** — true on the base: the only `wa session` verb
  was `start` (`git show 12fd4c12:lua/core/init.lua`, line 398).
- **"a stopped unit and a HOLD file are outside wa"** — true, and it is why item 3 exists: no Lua or
  script in this tree reads a `HOLD` file (`grep -rn HOLD lua/core/*.lua scripts/*.sh` finds only the
  comment I wrote). `~/Work/missions/flaky-rel-native-poll/HOLD` is a plain 80-byte text file
  (21/11 21:12 local = 22/11 00:12Z), untouched by any node code.

## What was built (every claim below cites its commit)

**Kernel state — `dfa88ca9`.** A park is a hold in the table that already holds holds:
`self_wake_pauses` gains `kind` (`'pause'` for the 13/11 interrupt hold, `'park'` for this), by a
conditional `ALTER` for a ledger written before it (`lua/core/selfloop.lua:107,124`). So every existing
reader honours a park with no second rule:

- `selfloop.hold(session)` — the row with its kind (`selfloop.lua:711`);
- `selfloop.park(...)` (`:733`) is idempotent (first time and reason kept) and **upgrades** an interrupt
  hold to a park without moving `paused_at` — the schedule stopped when it stopped;
- `selfloop.release(...)` (`:767`) deletes a park row only; an interrupt hold is refused by name
  (`session_held_by_interrupt`) with the command that does lift it (`wa chat --resume <id>`);
- `selfloop.resume` — the single door `wa chat --resume`, `wa resume --session` and a user message all go
  through — answers `parked` and lifts nothing (`:672`); its own `DELETE` is scoped `kind<>'park'`;
- `summary`/`list` carry `parked` (`:501,:528`), and the footer of a parked session says
  `⏰ 2 wakes held (session parked)` instead of `paused` (`selfloop.lua` footer_text, `dfa88ca9`).
- The tick needed no change: it already reads every hold once per tick and skips those sessions on both
  paths (the Lua loop and the component's `plan`), so a parked session's due wake is counted `held` and
  dispatched to nobody.

**The verb — `dfa88ca9`.** `lua/core/session_park.lua`: `wa session park <id> [--reason <text>]
[--mission <name>] | release <id> | status [<id>]` (`M.park:77`, `M.release:122`, `M.status:173`,
`M.cli:257`), dispatched from `lua/core/init.lua:411`. An id, or a unique prefix of one (two matches are
refused by name with both ids, never guessed). `--mission <name>` reads the session the mission
directory already recorded through `mission.status` — `run.lock`'s `SESSION=`, else the `wa: session <id>`
line in `out.log` — so the stop recipe needs no id.

**The refusal — `dfa88ca9`.** `lua/core/chat.lua:282` refuses a parked session for `--resume`,
`--session` **and** `--continue` (one check after the thread is resolved, before anything is drawn or
sent), exit 2, naming `wa session release <id>`. `wa resume --session <id>` prints `wakes held: this
session is parked` plus the release command (`lua/core/init.lua:246`).

**Docs and the factory line — `4a65568f`.** `docs/SELF-LOOP.md` gains "Park: the operator stops a
session", including the one line a stop recipe runs.

**Inventory and wiring — `c67c0ae9`.** The new code in `selfloop.lua` put `session_held_by_interrupt`
into the refusal inventory; `lua/core/refusal_codes.lua` was regenerated (the fast path's
`test-refusal-contract` and `test-regenerate` rows failed on `dfa88ca9`+`4a65568f` and pass on
`c67c0ae9` — one added line, 585 codes).

## Item 3 — the one line the factory's stop recipe must run

```sh
wa session park --mission <name> --reason "HOLD written: mission stopped"
```

Where it goes: the script that writes `~/Work/missions/<name>/HOLD` and stops the unit, immediately
after writing it. `--mission` resolves the session from the mission directory itself (`$MISSION_ROOT`,
default `~/Work/missions`), so the recipe needs no id and no other state; if the directory records no
session it refuses by name (`no session for mission <name>: mission_no_session`) instead of parking
nothing silently. Verified end to end on a scratch mission directory in
`scripts/test-session-park.sh` (`wa session park --mission hold-mission --reason ...` -> `parked
<id>`, and `release --mission` afterwards).

## Item 4 — the test, on a real ledger in a scratch home

Two halves, both wired in:

- `scripts/test-session-park.lua` — a fast-path Lua row by name (and an explicit row in
  `scripts/test.sh:1343`). Real SQLite ledger, real `selfloop` tables, real `selfloop.tick`, a counted
  scheduler stub, no model. **68 checks**: a due wake IS dispatched (the control, so a later zero is the
  park and not "nothing was due"); parked, an overdue wake dispatches nothing, the tick counts it held,
  and it keeps its id/`due_at`/reason/prompt with no new message; `status` says `parked since` / `1 wake
  held`; `selfloop.resume` and a user message lift nothing; release makes the same wake due and two ticks
  run it exactly once; releasing an unparked session is a refusal; a park upgrades an interrupt hold
  without moving its `paused_at`, and `release` refuses an interrupt hold; ambiguous and unknown ids are
  refused by name. It refuses to run against a live node home (`scripts/lib/test-home-guard.lua`).
- `scripts/test-session-park.sh` — the operator path across processes (wired into `scripts/test.sh:1344`
  and `scripts/fast.sh:856`, `check session-park`). Its own HOME and ledger under `$TMPDIR`, no
  rendezvous, no relay, no network, no model. `wa session park` in one process, `wa session status`,
  `wa chat --resume` (exit 2) and `wa chat --continue` (exit 2, its own ledger) in others, and the node's
  own tick in a third through `scripts/lib/session-park-e2e.lua`; the wake it holds is a
  `deploy_pause.RESUME_REASON` row, i.e. the wake of the 22/11 incident.

**Both fail on the base** (`12fd4c12`, a separate worktree, no stash): the Lua half dies on
`lua_root_unreadable: .../lua/core/session_park.lua`, the shell half with 30 assertion failures
(`unknown command: session`). `scripts/test-discriminates.sh 12fd4c12` reports `discriminates=1`
(scripts/test-session-park.sh), `environment=1` for the Lua row — that runner's scratch worktree has no
`wa` binary, so it names the row unjudged rather than passing it; the manual base run above is the
evidence for that half.

`scripts/fast.sh` (narrowed to the rows this change touches, `WA_FAST_ROWS`, under
the suite lock): all green, including `scripts/test-session-park.lua`, `check session-park`,
`test-selfloop.lua`, `test-selfloop-pause.lua`, `test-deploy-pause.lua`, `test-deploy-resume.lua`,
`test-session-fork.lua`, `test-session-owner.lua`, `test-compact-idle-pending.lua`. The neighbouring
suites were also run directly on this tree: `test-selfloop-pause` 101 checks, `test-selfloop` 114,
`test-deploy-pause` 23, `test-deploy-resume` 25, `refusal contract` 16974.

## What a park does NOT do (named, not implied)

- It does not kill a run already in flight. A row already `dispatching` is settled `unknown` and never
  replayed (`selfloop.lua` tick); nothing here claims to have stopped that turn.
- It does not touch a subagent child's own schedule.
- It does not cancel a wake: the rows are never rewritten.
- It does not refuse a message posted to a **served** session over the window's run API. Parking is
  about a schedule the machine drives itself; blocking a user's own message to their own session is a
different decision, and the brief asks for the wake and the resume.
- It does not read or write `HOLD`; that file is the recipe's business (item 3).

## Texts to approve (operator-facing, verbatim)

`wa session park <id>`:

```
parked <id>
  since <YYYY-MM-DD HH:MM>
  reason: <reason | no reason given>
  <N> wake(s) held[(<M> already due, fires once on release)]
  no turn runs for this session; release it with: wa session release <id>
```

(second park: `already parked <id>`; `--mission` with no session: `no session for mission <name>:
mission_no_session` plus `  a mission records its session in run.lock (SESSION=) or in its out.log (wa:
session <id>)`)

`wa session release <id>`:

```
released <id>
  <N> wake(s) pending again[(<M> already due, fires once)](next due <YYYY-MM-DD HH:MM>)
```

refusals:

```
<id> is not parked; nothing to release (<N> wake(s) pending)
<id> is held by an interrupted run since <time>, not by a park:
  there is nothing to release; coming back to the session re-arms it: wa chat --resume <id>
no such session: <id>
list them with: wa sessions
that is not one session: <id>, <id>
name it in full: wa session park <id>
```

`wa session status [<id>]`:

```
<id>  parked since <time>  <N> wake(s) held  reason: <reason | no reason given>
<id>  held by an interrupted run since <time>  <N> wake(s) held
<id>  not parked  <N> wake(s) pending
no session is parked
```

`wa chat --resume <parked>` (exit 2):

```
session <id> is parked[(<reason>)]: it runs no turn until it is released.
release it with: wa session release <id>
```

`wa resume --session <parked>`:

```
  wakes     held: this session is parked[(<reason>)]
            release it with: wa session release <id>
```

footer of a parked session: `⏰ 2 wakes held (session parked)` (interrupt hold keeps `⏰ 2 wakes paused`).
`wa --help` gains: `session park <id> [--reason <text>] [--mission <name>] | release <id> | status
[<id>]` / `hold a session's schedule and refuse to resume it; only release lifts the hold`.

## How to test it by hand (what Victor asked for)

```sh
wa session park <id>            # on a session with a scheduled wake
wa session status <id>          # "parked since ... N wakes held" - and the session gets no new message
wa chat --resume <id>           # refused, exit 2, names the release command
wa session release <id>         # the wake is due again; the node's tick runs it once
```

Two things a reader should know while doing that: the count in `wa session status` is the number of
wakes the hold is keeping (an overdue one is counted separately), and the resumes that do NOT lift a
park are exactly `wa chat --resume/--session/--continue`, `wa resume --session` and a message in the
session — by design, because a hold the session's next visit undid is not a stop.
