# call-followup: stopped at the brief's own gate (0 of 10 readable wakes)

Branch `change/call-followup`, base `5972aa7a`. **No code was written.** The brief's first
instruction is a gate, and the gate closed:

> RE-MEASURE: from the ledger, take the last 20 handle wakes and note what the model's next script did
> with the result (ran a fixed next step that could have been written up front / needed judgment /
> nothing). That share is the saving. **If under a quarter could have been written up front, STOP and
> report: do not build.**

Measured on this node on 22/11: **0 of 10 readable handle wakes** were followed by a step the answer
fixed in advance. 5 needed judgment, 5 needed nothing at all, and **in the four wake rounds whose execution evidence I
searched, none called `wait(op)` or `results.get(op)`** - the wake row already carries the answer, so
there was nothing mechanical left to fetch. 0 % is under a quarter, so this branch is this document and nothing else
(`git diff 5972aa7a --stat` shows one file).

## The premises, re-measured (and which were stale)

| premise | brief said | measured 22/11 | verdict |
| --- | --- | --- | --- |
| `wa counters` wake_only_round | 8 total | **12** cumulative | stale |
| `wa counters` script_cut_at_cap | 56 total, 3 today | **112** total, **59** on 2026-11-22 | stale |
| `wa counters` handle_mishandled | 0 | **0** | exact |
| handle wakes in the ledger | "self_wakes holds 14 rows with id like `handle:%`" | **22** records carry `woke_at` in `~/.wasm-agent/codemode-pending/*.json` (21 when this read began, one more at 15:39:40Z during it) | stale |
| `handle_wake.lua` schedule / sweep | :91 / :108 | `function M.schedule` :91, `function M.sweep` :108 | exact |
| the sweep tick | 2 s | `lua/core/selfloop.lua:24-26`: `wa_orchestrator_tick`, every 2 s, `lua/core/subagents.lua` | exact |
| the guest cap | 300 s | `rust/wa-capabilities/src/quickjs.rs:121`: `ms.clamp(1,300000)` | exact |
| "The limitation, named" | docs/CODEMODE.md | :244 | exact |
| `codemode_pending.lua:898` = "a call answers a handle" | :898 | :898 is a comment inside `stoppable`; the handle answer is `handle` :925 and `M.invoke` :981 | stale line |
| `codemode.lua:265`, `:591` = the handle globals | :265, :591 | the guest-globals list is :602 (`:260` is the comment above it) | stale line |

`wa counters --json` this run: `{"2026-11-22":{"handle_mishandled":0,"script_cut_at_cap":59,"wake_only_round":4},"handle_mishandled":0,"script_cut_at_cap":112,"wake_only_round":12}`.

One arithmetic fact the brief's plan should carry: **22 wakes produced 12 wake-only rounds**, so 10 wakes
were claimed by a session that ran no model round at all (parked, ended, or a prefix frozen with no
tools). Twelve rounds is the absolute ceiling on what a follow-up could ever have saved on this node's
whole recorded history.

## The corpus: 22 wakes, in the order they settled

Read through `tools.search_messages` (the node's own store refuses `bash`: `secret_path_denied`, by
design), anchored on each record's `woke_at` and read forward to the first assistant message of that
session. All times UTC.

| # | settled | session | call | the model's next step | verdict |
| --- | --- | --- | --- | --- | --- |
| 1 | 00:49:49Z | 70977830 | operation, failed | `no_dispatchable_tools`: the session's prefix was frozen with an empty tool list | nothing |
| 2 | 00:49:49Z | (none) | operation, failed | - | unread: the record names no session |
| 3 | 00:49:49Z | 55ea19fc | bash, failed | "The op that ran the load proof detached mid-way (11/20 green). First I check whether that harness is still alive before starting anything." (seq 199) | judgment |
| 4 | 00:49:50Z | 18d943df | operation, failed | - | unread: no assistant row in the window |
| 5 | 00:49:51Z | 9e4aadc8 | operation, failed | - | unread: same |
| 6 | 00:49:51Z | 470c6451 | operation, failed | - | unread: same |
| 7 | 00:49:52Z | 67a48738 | operation, failed | - | unread: same |
| 8 | 09:52:24Z | (none) | operation, done | - | unread: the record names no session |
| 9 | 10:08:53Z | (none) | operation, done | - | unread: same |
| 10 | 10:12:22Z | 09fe1cb3 | bash, done | "The fast-path failures are all 'no embedded code-mode assets' - my binary was built with `WA_CODEMODE_ALLOW_EMPTY=1`" (seq 289) | judgment |
| 11 | 11:21:26Z | fece6285 | remote, done | "Removed the 5 px left/right gutter on the content area." (seq 146) | judgment |
| 12 | 11:44:05Z | a949940c | operation, done | - | unread: no assistant row in the window |
| 13 | 13:23:29Z | df04c455 | operation, failed | - | unread: same |
| 14 | 13:27:37Z | 6d202e10 | operation, done | "The discrimination harness hands my row the branch's binary with the base's Lua, so a pty row cannot judge it - I'll make…" (seq 266) | judgment |
| 15 | 13:54:53Z | 6d202e10 | operation, failed | "Now the two additions: the row's honest skip, and a test for the pasted-path clause." (seq 297) | judgment |
| 16 | 15:01:00Z | 6d202e10 | operation, failed | "deploy waiting: waiting for the install of eb084ca88910…" (seq 418) | nothing |
| 17 | 15:15:02Z | ea127801 | operation, done | "deploy waiting: … 5972aa7a694d …" (seq 368) | nothing |
| 18 | 15:18:56Z | ea127801 | operation, done | the same deploy-pause line | nothing |
| 19 | 15:25:12Z | ea127801 | operation, failed | the same deploy-pause line | nothing |
| 20 | 15:25:12Z | (none) | operation, failed | - | unread: the record names no session |
| 21 | 15:30:36Z | 2973cc07 | operation, done | - | unread: no assistant row in the window |
| 22 | 15:39:40Z | 6d202e10 | operation, failed | - | unread: no assistant row in the window (the session was in a deploy pause) |

**Readable: 10. Fixed next step that could have been written up front: 0. Judgment: 5. Nothing: 5.**

## The decisive check: no wake round ever fetched the answer

For the four windows with the most traffic (6d202e10 at 13:27:37Z and 13:54:53Z, 09fe1cb3 at
10:12:22Z, and the ea127801 batch) a search of the execution evidence for `wait(` and
`results.get(` inside the minutes after each settle found **no call of either verb** - the only hits were
an operation result banner, a doc line that contains the word, and a failing test named
`test-codemode-wait-bound.lua`. That is the point of the measurement, stated plainly: the wake row
(`handle_wake.prompt_for`, 8 KiB clip) already carries the settled answer in the same flat shape
`wait(op)` answers, so the model never has to take a mechanical step to get it. What it does with the
answer is judge it - update a report, diagnose a broken build, plan the next test - which is exactly
the work a follow-up cannot do ahead of time.

## What this measurement does not cover, named

- 12 of 22 wakes are unread: 4 name no session in their record, and 8 have no assistant row that
  `search_messages` would surface in a window after the settle (compaction, or a session that never ran
  again). Unknown is not no: I do not claim they were judgment, only that nothing observed supports
  them being fixed steps. Even if all 12 had been pre-writable the share would be 12/22, and the ten
  that are readable say 0.
- The population **cannot** contain the pattern the feature is for. Today a model has no way to attach
  a follow-up, so the closest available proxy is the question above: was the step the model took fixed
  by the answer? It was not, ten times out of ten.
- `search_messages` ranking is fuzzy (the same window asked twice can return different rows), so a
  handful of the "unread" ones may be readable by another anchor. That would not move a 0/10.

## What the 0 means for the plan, and the one decision left

The saving the feature promises is "the lines after the slow call run without a model round". On this
node, over the whole recorded history, those lines were never mechanical: 12 rounds existed at most,
and every readable one of them was judgment or nothing.

Two ways forward, and they are Victor's to pick:

1. **Accept the measurement: do not build.** This branch is the report, and the mission is closed.
2. **Trial first, then decide.** Build `after(op, {code, input})` only far enough to run the brief's own
   item-7 trial (*"run the fast tests on this repo, then tell me the three slowest"*, 10 runs on the
   worker model and 10 on a frontier model, counting used-unprompted / right-first-time / fell back to
   `wait`), and keep the feature only if models take it up unprompted. That trial is the only
   measurement that can see the pattern this corpus cannot contain - it is not a substitute for the
   gate, it is a bet that the gate's corpus is the wrong population.

Nothing in item 5 (never block the 2 s tick), item 6 (prompt cache) or item 9 (authority) becomes
cheaper by waiting: all three are unchanged by this measurement.

## Texts to approve

None. This branch adds no model-facing and no operator-facing string.

## Tests

None added, and deliberately: there is no code to test. `scripts/test-discriminates.sh` will find no
new or changed test on this branch - it is a measurement-only branch, so the land gate's discrimination
check has nothing to run and its "no test changed" answer is the expected one.
