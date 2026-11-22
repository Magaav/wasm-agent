# script-writes-show-diff — every file a run creates, edits or deletes is a card

Branch `change/script-writes-show-diff`, base `c6f890e3`, two commits: `f5403d2e` (the event and the
card) and `fcea7d22` (the order it is drawn in, and the agent-loop test). Committed locally, **never
pushed**, and nothing was installed: every run below used
`/home/victor/wasm-agent/target/m-script-writes-show-diff/release/wa`, built from this worktree.

Victor (22/11 20:30Z, with a Claude Code screenshot): "everything once we create/edit/delete a file must
appear as claude code. we like to see everything. right now we only see like" a row "write 24ms".

## The premises, re-measured (rule 9)

| brief says | measured |
|---|---|
| `lua/core/agent.lua:3999-4010` emits the change only for a call named write/edit | confirmed, the block was `agent.lua:3996-4011`; it is gone in `f5403d2e` |
| `changeset.record` (`tools.lua:1932,1941`) stores both sides, also from a script | confirmed at `tools.lua:1927` (write) and the callback at `tools.lua:1941-1943` (edit) |
| `chat.lua:103-108` forwards the event | confirmed, unchanged and extended in `f5403d2e` |
| the settled inner-call row is `cli_view.lua` codemode_call ~3271 | confirmed |
| a delete can come "through the file tools" | **wrong**: the host has no `remove_file` (`changeset.lua:14-16`) and no tool removes a file. A delete only arrives through a command |
| a delete that `bash_changes` reports "with a recorded before-text" | **partly wrong**: `bash_changes` needs a git work tree (`bash_changes.lua:38-44`) and used to answer a removal with `index_text_unavailable` - a wrong sentence about a change that did happen. In `/tmp`, where Victor's own test writes, it sees nothing at all |
| "after a run settles (or as each inner call settles, if cheap)" | the second half is **not safe as stated**: a card emitted inside the dispatcher is written while the call's code-mode block is still open. Hence the queue in `fcea7d22` |
| - | **measured:** a `bash` called from a script never takes the foreground path: `codemode_pending.lua:427-435` sets `ctx.parallel_start`, so the call becomes a managed operation. A probe placed only in the bash branch never runs for a scripted command (it ran for nothing in my first attempt) |

## What changed, by commit

### `f5403d2e` — the event, and the card's words

- `lua/core/tools.lua` (`announce_change`, line 1355; its call sites are `tools.lua:2030` and `tools.lua:2047`) — one `change` event per applied `write`/`edit`,
  emitted from the tool's own branch. That branch is the single door every call passes: the model's
  direct call and a script's nested call (`tools.lua:1847-1862` hands the same ctx to
  `codemode.lua`, which dispatches each inner call through `M.dispatch`). The record is the CALL's own
  before/after text, so a script that writes a file and then edits it draws a `Create` and an `Update`
  rather than the run's starting point twice. Nothing on the result path is touched.
- `lua/core/tools.lua` (`announce_gone`, line 1386; called at `tools.lua:1963` for a foreground command, and at `tools.lua:1677` when an operation settles) — a command that removed a file the run wrote is a
  `Delete` card with its real lines. Probed through the run's own record plus `host.path_kind`
  (`missing` only), never parsed from a command line; each path is reported once. Called from the
  foreground bash branch and, in the same commit, from the `operation` branch when a state `settled`
  (`f5403d2e` also carries the second call site, since a scripted command is an operation).
  A file the run never wrote and a command removes outside a work tree is **not** seen - that is a
  named limitation, not a guess.
- `lua/core/agent.lua` — the loop's own emission is removed (it is what missed the script, and keeping
  it would draw every direct write twice): `agent.lua:3996` is now a comment saying where it moved.
- `lua/core/diff_view.lua:205-218` — the card's first two rows are `Create(<path>)` /
  `Update(<path>)` / `Delete(<path>)` and `Added N lines, removed M lines`, then the numbered rows with
  `+` green and `-` red (unchanged bands), two context rows per hunk, and the existing fold
  (`... +K more lines: /console shows all`) after `diff_view.MAX_BODY`. The old first row
  (`<path>  +N -M`) is gone.
- `lua/core/bash_changes.lua:93-117` — a removed tracked file is a change with its index text and
  `deleted = true`, so the block draws a `Delete`; only when no text is left to show does it refuse,
  with `deleted_text_unavailable`.
- `lua/core/cli_view.lua:3211` — a `remote_change` event draws one honest row, `wrote <path> on <node>`
  or `could not write <path> on <node>: <why>`; `diff_block` passes the `deleted` fact through.
- `lua/core/chat.lua:107-116` — an allow-list: `deleted` on a change, and the `remote_change` type.
- `lua/core/changeset.lua:215-216` — `RECORD_CAP` and `line_delta` exported, so the card and the undo
  entry cannot disagree about what is recordable or how many lines moved.

### `fcea7d22` — the order a reader sees

- `lua/core/agent.lua:2406` — the run carries one queue (`self.change_queue`), handed to every call
  (`agent.lua:3753`) and drained in place right after that call's `tool_result` (`agent.lua:4000-4013`).
- `lua/core/tools.lua:1349` (`deliver`) — the event goes into that queue when the caller has one, and
  straight to `ctx.emit` otherwise (a bare dispatch, a test).

## Tests (rule 3: wired where a run finds them)

- **new** `scripts/test-script-writes-show-diff.lua`, wired into `scripts/test.sh` next to the
  diff-view row (`WA_SCRIPT=... "$BIN" --db "$DB.script-writes-diff"`, `f5403d2e`), and in the fast
  path by default (every `scripts/test-*.lua` not listed in `scripts/fast-path.exclude`). 33 checks,
  through a **real** script (`tools.dispatch -> codemode -> the nested dispatcher`): create, edit and
  remove in one script give three change events (Create, Update, Delete) and their cards; the
  model-visible result is byte-identical with a listener and without one; a queue means nothing is
  emitted until the drain; one agent-loop turn through a fixture provider (`scripts/lib/test-provider.lua`
  refuses the vault, `host.http` raises) draws exactly one card, after the call's result row, and the
  stored tool message carries no line of it; a `remote_change` draws one row.
- `tests/diff-view.lua` (+13 checks, 46 through the binary): the new words for Update/Create/Delete, a
  Delete card from a `change` event, and a real `bash_changes` removal drawn as a Delete.
- `scripts/test-chat-printer.lua` (+4 checks, 11): the printer keeps `deleted`, and forwards a
  `remote_change` with its failure.
- **Discrimination (rule 16), measured on a worktree of `c6f890e3`** with these three test files copied
  in and the base's own `lua/` loaded: `tests/diff-view.lua` exits 1 (six named FAILs on the card's
  words), `scripts/test-script-writes-show-diff.lua` exits 1 (0 change events for the run),
  `scripts/test-chat-printer.lua` exits 1 (`a removal keeps its path and its deleted fact`).

## The model's bytes (item 4) - how it was checked

Two measurements, both on this node:

1. `scripts/probe-prompt-bytes.lua` run against a worktree of `c6f890e3` and against this branch, each in
   its own scratch home: **identical** - `system_bytes` 20590, `envelope_bytes` 786, `codemode_bytes`
   1388, `prompt_bytes` 21376, catalogue 74 master / 23 guest, envelope `["run"]`.
2. The row test's byte check: the same script run twice, once with the reader's listener and once
   without it, answers the same JSON after `host.now` is frozen for both, and the stored tool message
   carries no card text. No tool schema, argument or prompt file was touched by either commit.

## Texts to approve (verbatim)

1. `Create(<path>)`
2. `Update(<path>)`
3. `Delete(<path>)`
4. `Added N lines, removed M lines`
5. `wrote <path> on <node>`
6. `could not write <path> on <node>: <error>`
7. `deleted text unavailable` (a `bash_changes` refusal reason, rendered by the existing
   underscore-to-space rule; it used to say `index text unavailable` about a removed file)
8. Kept as they were: `convenience view, not a review`, `... +K more lines: /console shows all`,
   `no diff shown: <why>`; removed: the old first row `<path>  +N -M`.

## Not done, and what is unknown

- **A write on another node is not exercised end to end.** The row is drawn and filtered by tests on
  both sides of the seam, and the emission is the `remote` branch of `lua/core/tools.lua` (one `deliver`
  call, `f5403d2e`), but no test drives a peer: this mission called no live node (rule 13) and a scratch
  peer with its own rendezvous was out of scope. Unknown, not "works".
- **Replay (item 5) is not implemented.** View events are emitted live and were never stored: the
  transcript keeps turns, not cards, so `wa chat --continue` shows the same rows it showed before this
  change (the tool result, no card). Doing it means persisting view events in the session record and
  drawing them on replay - more than a small change, so it is left, as the brief allows.
- **The full fast path, measured twice, and what it found (both named by the runner, not by me).**
  Run 1 at `fcea7d22`: 394 checks, 2 failed - `scripts/test-land-quick.lua` (exit 124, the watchdog
  killed it after 120 s with no verdict, classified `environment`) and this mission's own row
  (`FAILED 4`). `test-land-quick` passed in run 2, so that one was the machine.
  Run 2 at `4ed7e6a9`: 394 checks, 2 failed - the same row, and `install-guards` (6 checks), which fails
  the SAME 6 on a worktree of the base `c6f890e3` in this environment: it expects the `upgrade`
  candidate-commit guards and gets `upgrade: refused inside a turn running on the node it would
  replace`, i.e. this shell is inside a turn. **Pre-existing and environmental, not this branch.**
  The row's failure was real and is fixed: the verdict line added in `3fe4471b` named the first
  failing check (`the created file is named Create(path)`), and the cause was the CARD, drawn at a
  fixed width of 80, being cut inside its frame because the runner's scratch home makes the file's
  path ~105 cells deep - so the heading `Create(<path>)` wrapped onto two rows. Four path-shaped
  assertions failed on a card that was drawn correctly. `0e347215` draws the card at a width that
  fits its own path (verified with a home of the runner's shape); cutting inside the card stays
  `tests/diff-view.lua`'s subject at its own widths.
  Run 3 at `57c67aa0` (after the fix): 394 checks, 2 failed, and **this mission's row passed inside the
"
"  fast path**. The two that failed are neither mine nor stable: `install-guards` (above, reproduced on
"
"  the base) and `session-liveness`, which names an owner presence 4001 s old and passes standalone on
"
"  THIS tree and on the base (`ok session-liveness: 14 checks`, both) - a wall-clock row measured while
"
"  the suite and a node install were sharing the machine.
"
"  Narrowed reproduction is **not possible by row name**: `WA_FAST_ROWS` is a list of CHANGED PATHS
  (`scripts/lib/fast-rows.sh`), so a row name is refused by name - two attempts of mine therefore ran
  no rows at all and proved nothing. The full suite is the faithful door.
- **My own rule breach, reported rather than hidden:** one throwaway debug script of mine
  (`/tmp/swsd-dbg2.lua`, run by hand at ~22:15Z) drove a real agent loop whose provider seam was not
  stubbed, so it reached the operator's provider through `WASM_AGENT_VAULT_URL` and spent three model
  calls. It called no peer and no fleet service. The committed test refuses the vault by name
  (`scripts/lib/test-provider.lua`), and that refusal is what caught it.
- A file a command removes that the run never wrote, outside a work tree, draws nothing (named above).
