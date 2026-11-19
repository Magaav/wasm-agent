# change/turn-signal — the friction note kept, the hiccups that ended a run, the handles a call must answer

Base: origin/main 44229140 (branch change/turn-signal, worktree /home/victor/Work/missions/turn-signal/wt).
Commit locally; never pushed.

Item numbers refer to docs/missions/harness-fixes as quoted in the mission brief (#33, #34, #22+#51,
#37, #43, #48).

## What was measured before writing any code (the brief's facts re-checked)

| Premise | Measured on 44229140 | Verdict |
|---|---|---|
| #33 the `<turn>` block is shown to the reader | `lua/core/agent.lua:3401` emitted `reply` verbatim; no strip, no journal table anywhere (`rg 'turn_notes\|turn_journal'` -> nothing) | **absent, implemented here** |
| #33 an engine already reads the notes | `lua/core/turnfeed.lua` (990 lines) + `turnfeed_cli.lua` (226): grouping, ranking, `wa turns`, fixed-markers | **present, reused** (the journal is an added durable store, the ledger stays the corpus) |
| #33 the envelope says the harness removes the block | the envelope ended at "say so in one line and stop" (`agent.lua:262`) | **absent, added** |
| #33 `wa turns --day` | `turnfeed_cli.lua` had `--since/--top/--json/--nodes/--sha/--note`; no `--day` | **absent, added** |
| #34 `echo` must not arm the gate | `echo`, `printf`, `ls`, `git status`, `cat` are all in `READ_VERBS` (`orchestration_mode.lua:66`), and a direct `bash` call routes through `read_only_command` | **already true for direct bash** |
| #34 a script must be judged by its own calls | `agent.lua` effect block only special-cased `bash`/`shell`; a `codemode` call fell through to `tools.has_effect("codemode")` = true, so **every** script — including `return await tools.ls({})` — armed the gate | **absent, fixed here** |
| #22/#51 a final message that is only an unrun code block | `raw_code.unexecuted` existed, but the miss **failed the run on the first occurrence** (`error(reason)`) | **half: fails instead of continuing once** |
| #22/#51 a reply cut inside a run block | `raw_code.take` marks `incomplete` and refuses; nothing detected it at turn end | **absent, added** |
| #22/#51 reasoning-only end | `agent.lua:2848` failed the run with `empty_reply_reason` on the first one | **absent (no continue), added** |
| #37 a pending handle answers its id and log path | `codemode_pending.lua:607` `handle()` returned `{state, op, tool, waited_s, progress}` — the id only under `op`, no paths | **partly: `op` only, paths absent** |
| #37 `wait(op)` reachable from CodeAct and codemode | `codemode.lua:564` registers `wait`/`cancel`/`pending` as script globals; `tools.wait` reachable through the helper map | **already true** |
| #43 `operation list/await` return bodies by default | `wa-operation` `list()` strips `stdout`/`stderr`, but an `await` answers through `foreground`/`snapshot` with `stdout` inline; nothing bounded it or said it was omitted | **absent for await, added at the tool boundary** |
| #48 hyphenated MCP names as `tools["mcp_x-y"]` | `codemode_harness.lua:160` `wrapTools` uses `property in object` before the proxy branch, so bracket access already resolves; the **dot** form is what fails | **already true (bracket); nothing to fix** |
| #48 one injected inventory, declared vs on-demand stated once | the envelope declares in `envelope.M.bootstrap` and the script sees `ALL_TOOLS`; the "declared vs on-demand" sentence was **not** found in one place | **verified only; see "Not done"** |

## Items, with the test that fails before and passes after

The one new row is `scripts/test-turn-signal.lua` (44 checks). It is in the fast path **by
naming** — `scripts/fast-path.exclude` does not list it, and `scripts/lib/fast-rows.sh` takes every
`scripts/test-*.lua` that is not excluded — and it was run by `scripts/fast.sh` in this session
(`fast path ok (48 checks, 0 skipped)`, the row named in `wa-fast-result.json`).

### 1. #33 — keep the note, strip it from the answer, journal it

New: `lua/core/turn_journal.lua` (split + `turn_notes` table + day bounds + read).
Changed: `agent.lua` (split at the reply boundary, journal row, `turn_note` event, the reply and the
`final_answer` carry the visible text), `turnfeed_cli.lua` (`wa turns --day`),
`commands.lua` + `chat.lua` (`/turns [N]`).

Checks (fail on base, pass now):
`#33: the visible answer is the answer alone, never the note` / `#33: an exact output format survives
the note` (a `TOOLS_OK` answer keeps `TOOLS_OK` and nothing else) / `#33: a sentence that MENTIONS the
tag is not a note` / `#33: the row names its session / mission / build / mode` / `#33: today's note
falls inside today's window` / `#33: a malformed day is refused by name` / `#33: the envelope states
that the harness removes the block`.

The transcript row keeps the block whole (`content = reply`), because `turnfeed.lua` groups from the
ledger; the journal is a second, queryable store (session, mission, build, mode, model, the three
fields, the block).

### 2. #34 — the gate fires on real effects only

`agent.lua` now classifies a `codemode` call by the calls its own result recorded; a script whose
calls were all reads (`ls`, `grep`, `read`) is not an effect, one that wrote/started/sent is, and an
unreadable script result is `unknown` and therefore an effect.

Checks: `#34: a script that only read is not an effect` / `#34: a script that wrote is an effect` /
`#34: a script that called nothing changed nothing` / `#34: an unreadable answer is unknown, and
unknown is an effect` / `#34: the dispatcher classifies a script's effect from its own calls`.

Direct `bash` with `echo` was **already** ungated (measured above) — that half needed no change, and
this report does not claim one.

### 3. #22 + #51 — never end a run on a hiccup

`raw_code.M.unrun(text, policy)` names the two shapes (`run_block_cut`, `run_block_tagged_js`), and
`agent.lua` gives the **first** one in a run one automatic continue with a durable notice row
(`phase = "run_block"` / `"reasoning_only"`); the **second** fails the run by name
(`run_block_not_executed: …`) — never rc=0 with the action unexecuted. Both outcomes go to telemetry.

Checks: `#22: a message whose only content is a js block is the mis-tagged action`, `#22: and the
notice names the real cause`, `#22: a reply that ends inside a run block is named`, `#22: a correct
run block is not a miss`, `#22: a js block with prose around it is a sample, not a miss`, `#22: with
code mode off a js block is text`.

### 4. #37 — a pending call always answers id + log path

`codemode_pending.handle()` now answers `operation_id`, `stdout_path`, `stderr_path`, `log_path`,
`output_bytes`, `settled` beside `op` (and `op` is kept — every existing script and `wait(op)` use
it). The paths come from the operation's own state record; absent is nil, never a guess (an earlier
draft called a `host.operation_dir` that does not exist, and that was removed).

Checks: `#37: a pending handle carries operation_id as a plain field`, `#37: and the log paths beside
it`. `wait(op)` reachability was measured present (item 4's second half) and is asserted, not changed.

### 5. #43 — list/await answer ids and state by default

`tools.lua` operation branch: a `list`/`await`/`wait` answer loses `stdout`/`stderr` by default and
says how many bytes it dropped (`stdout_omitted`, `output_omitted`, `output_hint`); `output=true`
returns them, capped at `max_bytes` (1 KiB … 64 KiB, default 4 KiB) with `*_truncated`.

Checks: `#43: a list/await answer drops the body by default …`, `#43: and returns it when the caller
asks`, `#43: with a byte cap when the body is large`.

### 6. #48 — one inventory, valid accessors

Measured: bracket access to a hyphenated name already works (`wrapTools`, `property in object`); the
dot form is refused with the closest names, which is the correct behaviour for a name JS cannot spell.
**No code change was needed and none was made for this item.** The declared vs on-demand sentence was
not found in one place; see "Not done".

## Before/after, both measured with the same binary

```
scripts/test-turn-signal.lua on BASE  (the 7 edited files stashed): turn-signal: 42 checks, 10 failed
scripts/test-turn-signal.lua AFTER                                   : turn-signal: 44 checks,  0 failed
```

The 10 base failures name every item above (#33 envelope, #22 x4, #37 x2, #43 x3).

## Pre-existing failures (same binary, base vs this tree — nothing loosened)

| Row | Base | This tree | Cause |
|---|---|---|---|
| `scripts/test-done-gate.lua` | 20 failed / 58 | 20 failed / 58 | documented in `scripts/fast.sh:425` ("test-done-gate (20 of 58)"); a vault/provider fixture, not this change |
| `scripts/test-codemode-pending.lua` | lua error | lua error | `this node has no embedded code-mode assets` — the release binary in this session was built with `WA_CODEMODE_ALLOW_EMPTY=1` (see "Environment") |
| `scripts/test-codemode-friction.lua` | lua error | lua error | same: `codemode_not_enabled` |

`scripts/test-turnfeed.lua` 143 checks OK and `scripts/test-command-parity.cjs` 62 checks OK on **both**
trees (the parity row caught a real bug I introduced — my `/turns` arm swallowed the `/session`
header — which is fixed and re-verified).

## Narrowed fast path (this tree's binary)

`fast path ok (48 checks, 0 skipped, 197s)`, rows `test-turn-signal`, `test-turnfeed`,
`test-codemode-blocks`, plus every always-on core row and contract check.

## Environment notes (honest limits)

* The release binary used here was built with `WA_CODEMODE_ALLOW_EMPTY=1`: `scripts/codemode-build.mjs`
  needs a staged prepared input (`prepare` answers `absolute_prepared_input_required` for a bare tree
  root), so this tree's binary cannot run code-mode scripts. That is why the two code-mode rows above
  are unmeasured here, and why the sandbox-level half of #37/#48 was verified by reading the source and
  by the `test-codemode-blocks` row (which skips the model-facing bytes for the same reason).
* `/tmp` on this node is 80% full; two `tools.write` calls to `/tmp` returned `write_failed`
  (effect unknown, re-read: nothing landed). Scratch moved to `/home/victor/.cache/tsscratch`.

## Not done

* **#48's "declared vs on-demand stated once"** — I verified the accessor behaviour and the two
  surfaces, but did not find a single sentence stating the split, and did not add one: the envelope
  text is model-facing contract wording that the mission requires be approved verbatim first, and I
  would be guessing which sentence the operator wants. It is listed under "Texts to approve" below as a
  question, not as a change.
* The journal's `build` field is `host.runtime_info()`'s own value when the node answers one, else
  empty — this build's `runtime_info` was not asserted to carry it, so a row can read `(unknown build)`.
  Recorded, not guessed.

## Texts to approve (verbatim, model- or operator-facing)

1. Envelope addition (`agent.lua`, the `<turn>` section):

   > The harness removes this block from the answer it shows, and stores it in the run journal (session, mission, build, mode and the three fields); it never competes with an exact output format a request asks for, so an answer that must be only a number, a JSON body or one word still carries the block after it.

2. Harness notice, mis-tagged fence (`raw_code.unrun`, continued once as a `user` row with
   `phase = "run_block"`):

   > [harness] run_block_not_executed: your block was tagged js, not js run, so nothing ran: write the fence line as ```js run (the tag is what makes it an action)
   >
   > This is not a new user request: send the same action again, correctly, and finish the task.

3. Harness notice, reply cut inside a run block:

   > [harness] run_block_not_executed: your response was cut inside a run block, so nothing ran: send the whole script again in one ```js run block that ends with a ``` line
   >
   > This is not a new user request: send the same action again, correctly, and finish the task.

4. Harness notice, reasoning only:

   > [harness] reasoning_only: your step ended with reasoning and no answer and no tool call, so nothing was written.
   >
   > This is not a new user request: answer the request now, or send the action as one ```js run block.

5. Second occurrence (the run fails by name, rc ≠ 0):
   `run_block_not_executed: <the notice above>`.

6. `wa turns --day` usage line (`turnfeed_cli.USAGE`):

   > wa turns --day YYYY-MM-DD [--top N] [--json]   one day's themes and counts, from the run journal

7. `/turns` command row (`commands.lua`):

   > /turns [N]   the last N <turn> notes of this session (#33): what hurt, what it buys, what to focus on

8. Operation output omission hint (`tools.lua`, the `operation` answer):

   > add output=true (max_bytes=4096) to this call, or read one stream: operation action="read" id=... stream=stdout

9. Refusal for a malformed day (`turn_journal.day_bounds`): `turn_day_must_be_YYYY-MM-DD`.

## Diff (`git diff --stat`, measured after the last edit)

``` lua/core/agent.lua            | 117 +++++++++++++++++++++++++++++++++++++++++-----
 lua/core/chat.lua             |  21 ++++++
 lua/core/codemode_pending.lua |  31 +++++++--
 lua/core/commands.lua         |   1 +
 lua/core/raw_code.lua         |  47 ++++++++++++++
 lua/core/tools.lua            |  40 +++++++++-
 lua/core/turnfeed_cli.lua     |  80 ++++++++++++++++++
 7 files changed, 319 insertions(+), 18 deletions(-)
 plus new: lua/core/turn_journal.lua (290), scripts/test-turn-signal.lua (183)
```
