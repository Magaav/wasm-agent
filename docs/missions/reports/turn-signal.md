# change/turn-signal - the friction note kept, the handles a call must answer (round 2)

Base: `44229140` (origin/main at land59). Branch `change/turn-signal`, worktree
`/home/victor/Work/missions/turn-signal/wt`. **11 commits, not pushed.**

Round-2 scope is #33, #34, #37, #43, #48 only. #22/#51 and the finish contract belong to
`change/thinking-block`; `git merge-tree --write-tree HEAD change/thinking-block` is clean
(`8b2e8a19b822c0a8dd62ca20626c0b251f72c526`, exit 0, measured after the last commit).

## Premises re-measured before writing code (the brief`s facts, checked on this tree)

| Premise | Measured | Verdict |
|---|---|---|
| #22/#51 still on this branch after round 1 | `828f0d6c` removed `raw_code.unrun` (-47 lines) and the two auto-continues (-71/+10 in `agent.lua`); `rg "raw_code.unrun|reasoning_only"` finds neither in this tree | **done, and merge-tree clean** |
| `wa turns --day` reaches a verb | `turnfeed_cli.lua` dispatch took every leading `--` to the all-time report | **was absent, fixed in `6aee57b4`** |
| a `<turn>` split drops trailing text | round 1 concatenated outside the block only | **was absent, fixed in `e621a1e2`** |
| `run_body` carries the block | it returned the provider text | **was absent, fixed in `5c75978c`** |
| #34 rule reachable by a test | the rule was **inline** in the dispatch loop, so any test had to copy it | **was a copy, extracted to `M.script_effect` in `f6b0ed28`** |
| #37/#43 testable as code | `handle()` is a local; `invoke` and the `operation` tool are the real entries | **source:find, replaced in `f6b0ed28`** |
| a done-gate notice cannot glue | measured on the real view: the notice came out **above** the sentence it interrupted, which was then reordered after it | **was absent, fixed in `f6b0ed28`** |
| #48 bracket access to a hyphenated MCP name | `codemode_harness.lua` `wrapTools` resolves it; the dot form is refused by design | **nothing to fix, no code change** |

## Items and what proves each one

One row: **`scripts/test-turn-signal.lua`, 80 checks**. Wired into `scripts/test.sh` (`a04ced96`)
as its own line, with its own `mktemp -d` home and a `case` that refuses `~/.wasm-agent`; the row
also refuses a real home at its top (`error(... it refuses to run against a real node home)`).
Run through that exact line: `turn-signal: 80 checks, 0 failed`, rc=0.

### 1 (#33) the note is kept, stripped from the answer, journaled - `aedbe2b4`
`lua/core/turn_journal.lua` (new, 312 lines): `split`, the `turn_notes` table, `day_bounds`, `recent`.
`agent.lua` splits at the reply boundary and emits `turn_note`. Checks include
`#33: the visible answer is the answer alone, never the note` and
`#33: a sentence that MENTIONS the tag is not a note`.

### 2 (#33) `wa turns --day YYYY-MM-DD` - `6aee57b4`
Checks drive `turnfeed_cli.run`: `#2: wa turns --day exits 0 for a day it can answer`,
`#2: and answers THAT day, not the all-time report`, `#2: --json answers a JSON object for the same day`,
`#2: and the refusal names the format`.

### 3 (#33) the split keeps every byte on both sides - `e621a1e2`
`"<turn>..</turn>\n\n42"` answers `42`; `"Answer\n<turn>..</turn>\nP.S."` keeps `P.S.`; an unclosed
`<turn>` stays text and carries no note. Checks: `#3:` x6.

### 4 (#33) one dim row under the answer, expandable; `/turns` lists - `f7587c7e`, `4df24468`
`cli_view` handles `turn_note` and holds it until the run ends, so the row is under the answer
(`turn_notes_flush`). `M.turn_note_line` is pure and is asserted directly. `/turns [N]` reads the
journal the arm itself calls.

### 5 (#33) `run_body` returns the stripped reply - `5c75978c`

### 6 real code in the tests + wired row - `f6b0ed28`, `a04ced96`
* **#34**: the rule moved out of the loop into `agent.M.script_effect` (the loop now calls it, and a
  check asserts the loop calls it). The test drives that function: read-only false, write true,
  nothing-called false, unreadable true, `nil` true.
* **#37**: a real `codemode_pending.invoke(..., "bash", {command="sleep 30"}, nil, 0)` answers a
  pending handle; the test asserts `operation_id`, `stdout_path`, `stderr_path`, `op == operation_id`
  and `progress` beside them, then **cancels it** so nothing is left running.
* **#43**: a real `operation` start + `await` through `tools.dispatch`: id answered, no `stdout` by
  default, `stdout_omitted == 13`, `output=true` returns the body, a 3000-byte body under the cap
  comes back whole, `max_bytes=4` cuts it to the 1024 floor with `stdout_truncated == 3000`.

### 7 this report - `docs/missions/reports/turn-signal.md` (root `REPORT.md` deleted)

### 8 (#34) the done-gate notice is never glued - `f6b0ed28`
Measured with the same probe on both trees (real `cli_view`, captured writer), one delta before
the notice and one after:

```
BASE : <! done gate: 1 recorded check(s) still failing - continuing>
       <The answer is 42 and more>          <- the notice is ABOVE the text it interrupted,
                                               and the two pieces are merged on one row
THIS : <The answer is 42>
       <! done gate: 1 recorded check(s) still failing - continuing>
       <and more>                           <- own row, in order, no blank row
```

Six checks named `item 8:` assert that order, the absence of glue and the row's own `! ` mark.

### 9 `codemode_pending` - `9f61ae3a`
One #37 comment naming `stdout_path` **and** `stderr_path` (the duplicate block is gone:
`rg -c "Item #37" lua/core/codemode_pending.lua` = 1), and `docs/CODEMODE.md` documents the
handle with both paths.

## #48 (listed once, under what was done)

Verified, no code change: bracket access to a hyphenated MCP name already resolves in
`codemode_harness.lua` `wrapTools` (`property in object` is evaluated before the proxy branch), and
the dot form is refused with the closest names - correct for a name JS cannot spell.
**Not done**: the "declared vs on-demand, stated once" sentence - the envelope text is
operator-approved wording and I did not guess one. It is not claimed as done here.

## Before / after, same binary

`scripts/test-turn-signal.lua` run in a detached worktree of the **base** `44229140` (base code plus
`turn_journal.lua`, which the file loads) versus this tree:

```
BASE : 15 failed checks, then a lua error that ends the run
       (`:270: attempt to compare number with nil` - the turn_note event never arrives on base)
THIS : 80 checks, 0 failed
```

The base failures name each item: `#33: the envelope states that the harness removes the block`,
`#2:` x4, `#34: agent.lua exposes the rule its loop applies`, `#37:` x4, `#43:` x4,
`item 4: the stored note is one line under the answer`. Item 8 is the seventh check in
`f6b0ed28` and fails on base too (measured: `FAIL item 8: the text comes first, the notice after it`).

## Rows run here (all on this node, this tree)

| Row | Result |
|---|---|
| `scripts/test-turn-signal.lua` | 80 checks, 0 failed |
| `scripts/test-cli-flow.lua` | 14 checks, ok (the view change did not break it) |
| `scripts/test-turnfeed.lua` | 143 checks, ok |
| `scripts/test-codemode-blocks.lua` | 26 checks, ok (model-facing bytes SKIPped) |
| `scripts/test-done-gate.lua` | **20 failed / 58 - pre-existing**, documented in `scripts/fast.sh` |
| `scripts/test-codemode-pending.lua` | **not measured**: `this node has no embedded code-mode assets` |

`test-done-gate` fails the same 20 checks on the base tree (same binary, same count) and is named
as pre-existing in `scripts/fast.sh`; nothing here loosens or deletes an assertion.

## Environment notes (honest limits)

* This node's release build has no embedded code-mode assets, so `test-codemode-pending.lua` and the
  script-level half of the engine are not measurable here. The #37 check above drives the real
  `codemode_pending` Lua module under `WA_SCRIPT` and does not need the embedded assets.
* `rg` is available; no shell fallback was needed.

## Texts to approve (verbatim, operator- or model-facing)

1. Envelope addition (`agent.lua`, the `<turn>` section):
   > The harness removes this block from the answer it shows, and stores it in the run journal (session, mission, build, mode and the three fields); it never competes with an exact output format a request asks for, so an answer that must be only a number, a JSON body or one word still carries the block after it.
2. `wa turns` usage line (`turnfeed_cli.USAGE`):
   > wa turns --day YYYY-MM-DD [--top N] [--json]   one day's themes and counts, from the run journal
3. The day answers (`turnfeed_cli`):
   > wa turns --day %s: no note in the run journal for that day
   > wa turns --day %s: %d note(s) from %d session(s)
4. `/turns` command row (`commands.lua`):
   > /turns [N]   the last N <turn> notes of this session (#33): what hurt, what it buys, what to focus on
5. `/turns` output (`chat.lua`):
   > no <turn> note recorded in this session yet
   > (row) `  %s  %s` - the clock time, then the focus (or what hurt when no focus was named)
   > (row) `        hurt: %s` / `        buys: %s`
6. The stored-note row (`cli_view.turn_note_line`):
   > ◌ turn · <the focus, or what hurt>  … +N chars   (the fold opens the whole block)
   > ◌ turn · (kept in the run journal)   (when no field was written)
7. Operation output-omission hint (`tools.lua`):
   > add output=true (max_bytes=4096) to this call, or read one stream: operation action="read" id=... stream=stdout
8. Refusals, by name: `turn_day_must_be_YYYY-MM-DD`, `turn_note_missing`, `turn_journal_store: <what>`.
9. The pending handle's new plain fields (documented in `docs/CODEMODE.md`):
   > `{state:"pending", op, operation_id, tool, waited_s, stdout_path, stderr_path, progress}`

## Diff (`git diff --stat 44229140..HEAD`, this report excluded)

```
 docs/CODEMODE.md              |   9 +-
 lua/core/agent.lua            |  65 ++++++++-
 lua/core/chat.lua             |  21 +++
 lua/core/cli_view.lua         |  71 +++++++++
 lua/core/codemode_pending.lua |  29 +++-
 lua/core/commands.lua         |   1 +
 lua/core/tools.lua            |  40 +++++-
 lua/core/turn_journal.lua     | 312 +++++++++++++++++++++++++++++++++++++++++
 lua/core/turnfeed_cli.lua     |  93 +++++++++++-
 scripts/test-turn-signal.lua  | 318 ++++++++++++++++++++++++++++++++++++++++++
 scripts/test.sh               |  13 ++
 11 files changed, 959 insertions(+), 13 deletions(-)
```

## Not done, and unknown

* **#48's "declared vs on-demand stated once"** - not added; see above. No code change claimed.
* The journal's `build` field is `host.runtime_info()`'s own value when the node answers one, else
  empty, so a row can read `(unknown build)`. Recorded, not guessed.
* The Rust/engine half of #43 beyond `tools.lua` was not re-measured: the tool boundary above is
  what the checks drive.
