# chat-view-round-2

Branch `change/chat-view-round-2`, base `7865a08e`. Five commits:

| commit | what |
|--------|------|
| `1337b808` | `/status` mid-run: the limits read it has, with its AGE; the provider's own list cost summed instead of "cost unknown" |
| `b831037a` | a script's `tools.bash` reports the files it changed (creates included); a run block's result is ONE row the reader opens, plus Ctrl+O in the transcript |
| `446a1cca` | the cost on its own row (a wide Usage row was being cut by the panel), and the three pty rows, wired into the fast path |
| `a562ece8` | a peer's command names the files it changed; this node draws one row per file |
| `6599daee` | drop a probe script a measurement left behind |
| `eef97c22` | the three pty rows start tmux through `scripts/lib/tmux-session.mjs` (the row that guards against leaked servers found them), and `scripts/test-run-block-pty.mjs` reads the new one-row result |

Nothing was pushed, no release, no fleet, nothing on a live peer, no install into `~/.local/bin`, no `git stash`. Item 3 of the brief (the Create/Update card) was already landed by `change/diff-card-reads-like-claude-code` (base commit `edad0d39`): measured on the base, its card is drawn open with the blank row above and below, so it is NOT redone here and no file of `lua/core/diff_view.lua` was touched.

## The premises, re-measured before any code (brief rule 9)

| brief said | measured on base `7865a08e` | verdict |
|---|---|---|
| `/status` mid-run says "limits unavailable: read on the next /status between runs" (`lua/core/status.lua:228, 273`) | the lines are there (228 is `limits_of`, 273 the `limits unavailable` row) and a mid-run snapshot with a reading in hand draws the bars with **no age at all** | right, and the age was the missing half |
| "3 of 115 messages carry a change record" | **could not be re-measured**: the agent's own tools refuse the node's store (`403 secret_path_denied`, `lua/core/secret_guard.lua`) - `~/.wasm-agent/memory.db` is the node's, not the agent's. What was measured instead is the EMITTER side, through the real dispatcher in a scratch git work tree (below) | the count is Fable's, the emitter table is mine |
| "a peer bash that changed files says which files changed (the local bash_changes behaviour)" | the local behaviour only ever covered a DIRECT `bash`; a run block's `bash` - the only way the model runs a command on this node - emitted **nothing**, and a created file was invisible even on the direct path (`git status -uno`) | the brief understated it |
| "today a run block's result prints its first ~8 rows … then `operation op-… · the whole result is in /console`" | `lua/core/codemode_block.lua` `M.operation_note` appends exactly that sentence, the preview is `M.OPERATION_PREVIEW_ROWS = 6` | right |
| item 5: the result header changed from JSON to `status 200 · remote 200 · full_result <sha>` between the first two sessions | the system prompt and the `run` tool description are **byte-identical** across `f05b3150`, `5a4b1a29`, `5956ae15`; the only model-facing change is the bash result: 852 bytes / 35 keys → 200 bytes / 11 keys (`lua/core/bash_result.lua`, introduced between `f05b3150` and `5a4b1a29`) | the header did not change; the RESULT did |

### Which edits and writes drew a card on the base (through `tools.dispatch`, a scratch git work tree, 23/11)

| case | base | now |
|---|---|---|
| `write` (local) | `change` event → card | unchanged |
| `edit` (local) | `change` event → card | unchanged |
| `bash` DIRECT, modifies a tracked file | `bash_changes[1] tracked.txt` | unchanged |
| `bash` DIRECT, creates a file | **nothing** | a Create card (`-uall` snapshot, `b831037a`) |
| `bash` inside a run block, modifies | **nothing** | `bash_changes[1]` with both texts, one card (`b831037a`) |
| `bash` inside a run block, creates | **nothing** | one card, empty before side (`b831037a`) |
| `tools.remote` write/edit | the emitter exists (`lua/core/tools.lua`, the remote branch's `remote_change` and the `changeset.record` with the node) - not re-measured end to end, see "Not done" | unchanged |
| `bash` on a PEER that changes files | **nothing** (the watcher ran only for a caller with a local view) | the peer answers `changes` (path + counts, no text) and this node draws one row per file (`a562ece8`) |

## What each item is now

### 1. `/status` mid-run: the reading's age, and the provider's own list cost (`1337b808`, `446a1cca`)

* `lua/core/status.lua` `M.age_text(seconds)` says `just now` / `as of 4 min ago` / `as of 2 h ago` / `as of 2 d ago`, and `limits_of` now returns WHEN the reading was taken and whether this call read it (`fresh`) or drew one already in hand (`cached`). A cached reading draws the bars **and** the age row; a fresh one draws no age (a number taken now is not old); a process that never read says so by name and invents no age.
* The cost is its own row, short enough to survive any panel: `Cost     list $0.0010  ·  the provider's own list price, summed over 1 call`. Measured reason for the move: a `/status` panel in a 100-column pty CUT the Usage row at 40 cells (`Usage    in 1.0k  ·  out 100` was the whole row it drew), so a cost that sat at the end of it read as a cost that was missing.
* `lua/core/telemetry.lua` reads the provider's own price with an allow-list - `raw.opencode.list_cost`, and the flat `raw.list_cost` - keeps it apart from the rated `cost`, sums it over the session, and answers `list_cost_known` only when EVERY call that made up the total named one (a sum with a hole is not a cost). `lua/core/adapters/openai_completions.lua` passes the field through to the record.
* What is NOT done and cannot be: a **fresh** limits read DURING the run. The reading is one HTTP call and the interpreter is blocked inside the model call; a child process cannot do it either - the kernel withholds every provider credential from tool children (`rust/wa-operation/src/lib.rs` `DENY_ENV`, measured in `lua/core/idle_reads.lua`'s own header: "limits unavailable: provider not configured"). So the brief's "reads them fresh when that needs no run lock" is answered only where it already was: at the reader's own `/status` between runs. The mid-run panel now says how old its numbers are instead of refusing to show them.

### 2. Every edit and write draws its card, local or on a peer (`b831037a`, `a562ece8`)

* **A run block's command is watched** (`lua/core/codemode_pending.lua`): the watcher in the dispatcher's bash branch is unreachable for a script's bash (that branch starts a managed operation and returns), so the snapshot is taken before the operation starts and compared when it settles, and the event goes to the run's change queue - the same `bash_changes` the view already draws cards from. A read-only command takes no snapshot; an operation that has not settled claims nothing.
* **Created files are visible** (`lua/core/bash_changes.lua`): the porcelain snapshot is `--untracked-files=all` instead of `-uno`. Measured 0.010 s on this repository.
* **A peer's command names the files it changed** (`lua/core/tools.lua`, `lua/core/bash_result.lua`, `lua/core/cli_view.lua`): when the call asked for the change (`record_change`, the same word a write/edit already uses), the peer's answer carries `changes` - path, added/removed, created/deleted, **no text** - and this node turns each entry into one `remote_change` row: `created srv/app/main.py on peer-one (added 3 lines)`. The list is dropped from the value the model reads. `bash_result.KEEP` gained `changes` for exactly this reason (it is absent on a local call).

### 3. The Create card

Not redone: landed by the sibling mission (`05d7fa72`, `9fcdfe1b`, in `edad0d39`). Its `… +N lines (ctrl+o to expand)` and its blank row above and below are asserted by that mission's own rows, which are green here.

### 4. A run block's result is ONE row (`b831037a`)

* `lua/core/codemode_block.lua`: `M.tail_rows` builds the rows the result *would* print (uncapped, `expandable` off inside) and publishes ONE row - `⎿ script output · 2,549 chars` (thousands-separated, CHARACTERS, not bytes: ten `✓` are ten characters) - with the whole text as the fold (`rows.expand`). `M.failed` reads the same allow-list `M.operation_note` prints (a thrown error, a non-zero exit, the node's `failed` state): a FAILED script is drawn OPEN, its ERROR first (the preview now puts stderr before stdout, which it never did - a command that printed a line and then failed used to hide its own reason).
* `rust/wa-term/src/transcript.rs` `pin_toggle`: Ctrl+O opens the folded result line of the newest block and the same key folds it back - the row's own press (`expand_at`) does the same thing, so "click or Ctrl+O" is one behaviour with two doors. A block with no folded line keeps Ctrl+O as its pin (its own rust test says so).
* The per-call rows (`✓ remote · 907ms`) are untouched.

### 5. Why the commentaries stopped - REPORT ONLY

Measured, same probe on three worktrees (`f05b3150`, `5a4b1a29`, `5956ae15`), each tree's own Lua under this mission's binary, a fixed session and role:

| what the model reads | f05b3150 | 5a4b1a29 | 5956ae15 |
|---|---|---|---|
| system prompt | 27,540 B, sha `4cf3930e…` | identical | identical |
| the commentary cue (`When you start a new step with tool calls, first write one short sentence …`) | present | present | present |
| the `run` tool description | 566 B, sha `bdddbd9b…` | identical | identical |
| one bash result, same envelope | 852 B / 35 keys | 200 B / 11 keys | 200 B / 11 keys |

So **no prompt text changed** between the three sessions, and no tool description changed. The one thing that did change in what the model reads is the shape of a command's result: `lua/core/bash_result.lua` (mission slim-tool-results) stopped copying clocks, ownership, paths and containment into the window, between the first two sessions - the same two sessions whose commentary rate fell from 58/85 to 12/54.

That is a CORRELATION and I will not sell it as the cause. The replay the brief allows (one stored request per session, twice) is the measurement that would settle it, and it is outside this branch: the stored requests are in the node's own ledger, which the agent's tools refuse (`403 secret_path_denied`), and a replay is a paid provider call this mission is not authorised to make. **What Fable can do with this**: `wa` has no CLI that reads those payloads either (`docs/TELEMETRY.md`: "No `wa telemetry` CLI"), so the replay needs the ledger read by hand as Fable already did, then two identical requests (same model, same session prefix) - one with the pre-slim result shape substituted, one with today's - and a count of `answer_bytes > 0` over five runs each.

If the slim result IS the cause, the fix is a prompt-side cue, not a rollback (the bytes saved are real): a one-line addition to the preamble guideline, e.g. "a tool result is data; a step that changes something still wants its one sentence", measured against the same replay. **Proposal only - no prompt text was changed by this branch**, and any such change carries a cache cost: the guideline block sits inside the cached prefix (`lua/core/agent.lua`, `guidelines_for` -> `sections.render`), so one changed line re-prices the whole prefix once per session, not once per call.

### 6. What the model receives from a run block - REPORT ONLY

Confirmed as the brief describes: one header line (`status 200 · remote 200 · full_result <sha>`, `calls: <sha>:<bytes>`) and then the value the script RETURNED, whole, with stdout as a JSON string (`\n` escapes).

Byte comparison, measured on a 2,439-byte stdout with 39 newlines: the model receives **2,732 bytes** (JSON-in-a-string, plus the header) where raw terminal text would cost **2,608 bytes** - **124 bytes, 4.5%**, about 3 per newline. So raw stdout IS fewer bytes, and the difference is small: a candidate, not a change, and I did not make it.

## Tests, and where they run

| test | what it pins | on base | wired in |
|---|---|---|---|
| `scripts/test-status-midrun.lua` | 25 checks: the age wording, the bars with an age mid-run, no age for a fresh read, no invention without a reading, the summed list cost, a hole in the sum, the adapter's passthrough | fails (`age_text` is nil) | `scripts/test.sh` (`status mid-run ok`) |
| `scripts/test-status-midrun-pty.mjs` | 12 checks through the REAL binary in a private tmux pty: the bar and the list-cost row between runs, the same bar WITH ITS AGE mid-run while the model call is in flight, no "limits unavailable", the mid-run snapshot asks `/usage` nothing, and the run still completes (read back from the ledger by a second process) | **2 fail** (no cost row, no age row) | `scripts/fast.sh` (`status-midrun-pty`) |
| `scripts/test-script-bash-changes.lua` | 15 checks: a script's bash that modifies, one that creates, a file already modified is refused by name, a read-only command emits nothing, the direct path emits exactly ONE event | **9 fail** | `scripts/test.sh` (`script bash changes ok`) |
| `scripts/test-peer-bash-changes.lua` | 13 checks: the peer answers the list (paths + counts, no text), the caller emits one row per file and drops the list from the model's value, and the CLI draws the rows | **8 fail** | `scripts/test.sh` (`peer bash changes ok`) |
| `scripts/test-bash-changes-pty.mjs` | 8 checks through the REAL binary in a pty in a scratch git work tree: a run block's command creates a file, the card heading names it, its count row, the fold row still there, and the model's tool result carries none of the text | **3 fail** | `scripts/fast.sh` (`bash-changes-pty`) |
| `scripts/test-codemode-blocks.lua` (+60 lines) | the one row and its count (2,549 chars, ten `✓` are ten characters), the whole value in the fold, a failed script drawn open with its error first, a completed one still one row | fails (`block.failed` is nil) | already a row |
| `rust/wa-term` (two new tests) | `ctrl_o_opens_a_folded_script_output_row_and_the_same_key_folds_it`, `a_block_without_a_folded_row_keeps_ctrl_o_as_its_pin` | n/a (the binary did not have it) | `cargo test -p wa-term` |

Nothing the model reads changed: measured with the same probe on the base and on this tip - system prompt `27540 B / sha 4cf3930e…`, `run` description `566 B / sha bdddbd9b…`, and a local bash result `200 B / 11 keys` on BOTH.

### Regression rows run here (this session, this node)

`scripts/test-script-bash-changes.lua` 15 ok · `scripts/test-codemode-blocks.lua` 85 ok · `scripts/test-status-midrun.lua` 25 ok · `scripts/test-chat-printer.lua` 12 ok · `cargo test -p wa-term` green (202 lib tests among them, plus the new pair) · the three pty rows above, each green on the tip and red on a base worktree.

## The narrowed fast path, run here (suite rule: the rows my files touch)

`flock -o ~/Work/missions/.suite.lock env WA_BIN=<this tree's release build> WA_FAST_ROWS=/tmp/cvr2-rows.txt bash scripts/fast.sh`,
491 s, **128 checks, 3 failed**, over the rows for `status`, `telemetry`, `codemod-block`, `codemod-pending`,
`script-writes`, `cli-view`, `chat-printer`, the two whole-tree rows (`tool-schema-fidelity`,
`refusal-contract`) and the three new pty rows:

| failed row | whose | what was measured |
|---|---|---|
| `esc-stops-pty` - `bash: Esc brings the prompt back in under 300 ms` | **pre-existing**: the same row fails on a base worktree at `7865a08e` with this binary (825 ms against a 300 ms bound), and this branch touches no file of that path (`git diff --name-only 7865a08e HEAD` names none of `esc-stops`, `session_view`, the interrupt lane) | a load-sensitive bound on a machine that was installing builds all session |
| `tmp-cleanliness` (2 checks) | **pre-existing in the row, mine FIXED**: the row requires every `scripts/test-*-pty.mjs` to start tmux through `scripts/lib/tmux-session.mjs`. It named my three new rows and `test-diff-card-pty.mjs` + `test-esc-stops-pty.mjs`; mine were moved onto the helper in `eef97c22`, and the two that still fail are not this branch's (`diff-card` landed from the sibling mission, `esc-stops` predates it) | the leak guard works: it found exactly the rows that start their own server |
| `install-guards` (6 checks) | **environmental**: every failed check reports `upgrade: refused inside a turn running on the node it would replace; request the external sentinel instead` - the deploy-in-flight guard answered instead of the row's own subject, because the node was installing two builds while the suite ran (two failed `wa-deploy-*` units are still listed on this machine). No file of the upgrade path is touched by this branch | re-run when the node is idle |

Before `eef97c22` the same narrowed run failed 5 rows; the two that were mine (`run-block-pty`'s three
result-row checks, and the three pty rows in `tmp-cleanliness`) are green now:
`test-run-block-pty.mjs` 22 ok, `test-status-midrun-pty.mjs` 12 ok, `test-script-output-pty.mjs` 11 ok,
`test-bash-changes-pty.mjs` 8 ok, each run singly against this tree's binary.

## Not done, and open

* **`tools.remote` write/edit cards are not re-measured end to end.** The emitter and the `changeset.record` with the node are in the base (`lua/core/tools.lua`, the remote branch); exercising them needs a peer that signs its answers, and this session had no scratch peer (`WASM_AGENT_RENDEZVOUS` fixture answers unsigned, and the caller verifies - `nodes.verified_reply`). A peer's `bash` list IS measured, at the module seam the repository already uses (`scripts/test-federation.lua`) and through the real dispatcher.
* **A fresh limits read mid-run is impossible on this build** (see item 1). The brief's "reads them fresh when that needs no run lock" is met only between runs.
* **Item 5 has no replay.** The diff does not settle it (no prompt text changed), and the replay needs the ledger read by hand plus paid calls.
* FACTORY.md / HANDOVER.md were not written - the text is proposed below.

## Texts to approve (new or changed operator-facing strings, verbatim)

No model-facing string changed. These are drawn for the reader:

1. `  as of 4 min ago` - the age under a limits reading. Also `  just now`, `  as of 2 h ago`, `  as of 2 d ago`.
2. `Cost     list $0.0010  ·  the provider's own list price, summed over 1 call` - the cost when the provider named its own price (`calls` plural: `summed over 12 calls`).
3. `Cost     $0.0010  ·  rated` - the cost when this node's rate snapshot priced the calls.
4. `Cost     unknown` - neither number exists.
5. `⎿ script output · 2,549 chars` - a run block's result.
6. `created srv/app/main.py on peer-one (added 3 lines)` - a file a peer's command created; the other verbs are `changed <path> on <node> (added N lines, removed M lines)` and `deleted <path> on <node>`.
7. `could not run srv/app/main.py on peer-one: already_modified` - a change the peer could not attribute.

Unchanged and still said: `  limits unavailable: read on the next /status between runs`, `  … +N lines (/console shows all)`, `operation <id> · <state> · exit <n> · <ms> · the whole result is in /console` (now inside the fold on a successful script, on screen for a failed one).

## Proposals (for Fable to write - nothing below is in the tree)

**FACTORY.md**:

> *A command's changes are the reader's, whoever ran it.* Every path a run writes - by `write`, by `edit`, by a
> command, on this node or on a peer - draws the same card, or one row naming the path, the node and the count
> when the text cannot cross honestly. The event is emitted by the tool's own branch (one door), never by the
> loop, and a card is never part of the model's result.

**HANDOVER.md**:

> *A result is one row you can open.* A settled `run` block prints `script output · N chars`; a press or Ctrl+O
> shows the whole of it and the same key folds it. A FAILED script is drawn open with its error first. Nothing
> of the output is printed by default and nothing of it is lost.

> *A number on the screen says how old it is.* `/status` draws the limits it last read with `as of N min ago`
> and never refuses them because a run is in flight; the reading a run cannot take is named, not guessed.
