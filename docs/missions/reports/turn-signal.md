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
* The journal's `build` field is one of exactly two things, in this order: `host.build_identity()`
  when the host offers one, else `host.runtime_info().build_source_commit` - the commit the release
  binary embedded (`WA_BUILD_SOURCE_COMMIT`, rust/wa-capabilities/src/host.rs). Nothing else is
  read. An empty answer is stored as empty and a reader prints `(unknown build)`; the field is never
  filled from HEAD, from `commit`/`build`, or from the crate `version`, which is `0.1.0` for every
  build of this repo. Round 2's version of this field DID read `version` first, so a row could read
  `0.1.0` - a known-looking build that identified nothing; item 2 (round 3) removed that key and the
  checks pin it. There is no `host.build_identity()` in this tree today (measured: `rg -n
  build_identity` finds none), so on this node the field is `runtime_info().build_source_commit` or
  empty.
* The Rust/engine half of #43 beyond `tools.lua` was not re-measured: the tool boundary above is
  what the checks drive.

---

## Round 3 (review 19/11 03:40) - what changed, measured

Base: origin/main `e4e40405`. The branch was rebased onto it before any work; the rebase resolved one
conflict in `lua/core/raw_code.lua` (base landed the thinking-block verdict functions where this branch
had `M.unrun`; both were kept, then commit "item 1: drop #22/#51" removed `M.unrun` as it was meant to).

Four commits, each item committed as it finished:

| commit | item | `git diff --stat` |
|---|---|---|
| `87b8b523` | 1 | `lua/core/turn_journal.lua | 27 +++-`, `scripts/test-turn-signal.lua | 26 +++` - 2 files, 48 insertions(+), 5 deletions(-) |
| `7c680cb6` | 2 | `docs/missions/reports/turn-signal.md | 12 ++-`, `lua/core/turn_journal.lua | 55 ++++---`, `scripts/test-turn-signal.lua | 34 ++++` - 3 files, 89 insertions(+), 12 deletions(-) |
| `1e5352b0` | 3 | `scripts/lib/test-home-guard.lua | 84` (new), `scripts/test-turn-signal.lua | 76 +++-`, `scripts/test.sh | 13 ++-` - 3 files, 166 insertions(+), 7 deletions(-) |
| `7ddcf978` | 4 | 8 files, 255 insertions(+), 51 deletions(-) |

### Item 1 - the cleanup is the seam's (MUST)

`M.split` no longer runs one blanket gsub over the whole answer. It cuts at each closed `<turn>` and
joins the pieces through `seam(left, right)`: the spaces a cut stranded on the last line before it go,
and the newlines from both sides become one blank line between two pieces of text and no line at all
against the start or the end of the answer. An answer with no closed block never reaches that code, so
it comes back byte for byte. Tests in `scripts/test-turn-signal.lua` (run by the `turn-signal` row of
`scripts/test.sh`): indented code, trailing spaces, a markdown hard break, leading whitespace with a
blank first line, blank lines inside the answer, trailing blank lines and spaces - each asserted equal to
its own input - plus four seam cases (the cut collapses to one blank line; a leading block leaves no
blank line; a trailing block leaves none; a block-only answer reads as empty).

### Item 2 - the build is a commit, never 0.1.0 (MUST)

Round 2's `M.build_of` read `{build, build_commit, commit, version}`, and `version` is
`CARGO_PKG_VERSION` - `0.1.0` for every build of this repo, so every row claimed a known build that
identified nothing. It now reads exactly two things, in order: `host.build_identity()` when the host has
one (a string, or a table naming `build_source_commit`), else
`host.runtime_info().build_source_commit` - the release binary's embedded `WA_BUILD_SOURCE_COMMIT`
(`rust/wa-capabilities/src/host.rs`). Nothing else is read; an unreadable answer is empty = unknown,
which a reader prints as `(unknown build)`; bounded to `M.MAX_BUILD = 200`; `h` is injectable so the
eleven checks drive the rule with no node. Measured here: no `host.build_identity()` exists in this tree
(`rg -n build_identity` finds none), so on this node the field is `runtime_info()`'s commit or empty.

### Item 3 - the home guard refuses (MUST)

The old guard compared `WASM_AGENT_HOME` with `HOME .. "/.wasm-agent"`, and that can never fire: the host
resolves `HOME` FROM `WASM_AGENT_HOME` (`rust/wa-host-support/src/paths.rs`), so the process sees
`HOME == WASM_AGENT_HOME` and the right-hand side is `<home>/.wasm-agent`, never `<home>`. Measured with a
probe script on this node.

The rule now lives once in `scripts/lib/test-home-guard.lua` and in the same shape inline in
`scripts/test.sh`'s row:

* allow-list - the home must sit under `GATE_ROOT`, else `TMPDIR`, on a separator boundary (`/tmp/wa-10`
  is not under `/tmp/wa-1`). Anything else refuses without further inspection.
* the node's own markers - `<home>/.wasm-agent/node.key` or `<home>/.wasm-agent/memory.db` present means
  this is (or sits inside) a live node home. Measured here: `TMPDIR` IS `<state>/tmp`, so the allow-list
  alone would wave a home inside the state root through; the markers are what catch it.
* existence is asked with `host.canonical_path` which answers a path when it exists and nil when it does
  not, without reading it. Both probes are injectable, so the test needs no filesystem and no secret.

Measured end to end against the real script: a home outside the scratch root refuses; under the scratch
root with `node.key` refuses; under it with `memory.db` refuses; a clean scratch home runs (145 checks,
0 failed).
### Item 4 - the day report, the page, the fence (LOW)

* no crash on a day with no themes - confirmed first: the theme loop indexed `ranked[1]` and raised
  "attempt to index a nil value" when every word was a stop word. The report now prints
  `themes: none (no word in these notes survived the stop list)`.
* the page says it stopped - `M.count_day` counts the day exactly (`SELECT COUNT(*)`), the report compares
  that with the page it holds, and a capped day says so in the words quoted below. `--json` carries
  `total` and `truncated`. `M.recent`'s day query now takes the NEWEST N (`ORDER BY at DESC LIMIT ?`) and
  reverses to oldest-first, so a capped page is the recent part of the day rather than the morning.
* an inner bash call is judged like a direct one - measured: `M.script_effect` used
  `tools.has_effect(name, nil)`, so a read-only `bash` inside a script counted as an effect while the
  direct path used `read_only_command`. One function now, `M.command_effect(name, args)`, is called by the
  direct path AND by the codemode record site (`lua/core/codemode.lua`), which stores a single `read_only`
  bit on the call record (never the command text, and only when true). `M.script_effect` honours it for
  `bash`/`shell` and treats the bit on any other name as unknown = an effect.
* one page size - `M.STDOUT_PAGE_BYTES = 24 * 1024` and `M.STDERR_PAGE_BYTES = 8 * 1024` in
  `codemode_pending.lua`; the handle and `tools.lua`'s adopted-tree result both read them. The Rust page
  (`rust/wa-capabilities/src/operations.rs`, `24 * 1024`) and the operation schema's literal `24576` are
  pinned to the same byte by a check (a schema table cannot call a function, so that one copy is asserted
  rather than shared). The handle also reports `stdout_bytes` from `available_bytes`, the stream's real
  size, so `stdout_truncated` describes the whole output and not the page.
* the handle fields are documented - `docs/CODEMODE.md` now names `log_path`, `output_bytes`, `settled` and
  `state_name` beside `stdout_path`/`stderr_path`, and says what each is copied from (the local `handle` in
  `codemode_pending.lua`; a field the executor did not answer is absent, never guessed).
* one clock - the test took "today" from `os.date("%Y-%m-%d")`, the guest's UTC, while the bounds came
  from `platform.local_clock`. `M.local_day(epoch)` asks the clock `day_bounds` asks; the test uses it and
  asserts the two agree.
* a `<turn>` inside a code fence is code - confirmed first: the block WAS stripped and the fence emptied.
  `M.split` now finds fenced regions (three or more backticks or tildes, closing on the same character),
  and never treats a tag inside one as the answer's note; a real block after a fence is still the note.

### Texts to approve (round 3, verbatim)

Operator-facing, from the day report (captured by running it on a seeded day):

    read the newest 2 of 4 note(s) that day (--limit raises the page, up to 500)
    themes: none (no word in these notes survived the stop list)

Model-facing: none added this round. Item 4 changed how an existing call is judged, not what the model is
told: no notice, refusal or tool description changed.

### Not done, and unknown (round 3)

* `host.build_identity()` does not exist in this tree, so item 2's first source is a rule the host may one
  day satisfy rather than a path measured alive here. Said as much above.
* The inner-call `read_only` bit is recorded by the Lua codemode loop. A call that never reaches that
  record site (a refusal, a schema rejection) carries no bit and is judged unknown = an effect, which is
  the safe direction and is asserted.
* Pre-existing failures, measured on base `e4e40405` in a SEPARATE worktree (`git worktree add`, never
  stash) and unchanged by this round: `test-done-gate.lua` (20 failed, 58 checks - same count and same
  first failures on base), `test-raw-code.lua` ("switch on: the guidance sentence is in the system
  prompt"), `test-codemode-default.lua` (`DEFAULT_POSITIVE`) and `test-codemode-pending.lua` (this node has
  no embedded code-mode assets). None is touched by this round's diff.

* The 24 KiB number is still a literal inside the operation tool's JSON schema. It is asserted equal to
  `codemode_pending.STDOUT_PAGE_BYTES` by a check rather than shared, because a schema table is data.
