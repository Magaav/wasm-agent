# Esc stops what it started (week 1, priority 1)

A stop - Esc, `/stop`, a steer that cancels, a turn's deadline - ends the command the turn was waiting
on: its whole process group gets SIGTERM and then SIGKILL after a stated 250 ms grace, the wait wakes on
the cancel instead of at the end of its slice, the reader is told what was stopped and whether anything
survived, and work the turn started DETACHED on purpose is left running and named instead.

Branch `change/esc-stops-what-it-started`, base `origin/main` = 70eb209d (the v0.1.2 cut). Nothing in
this branch is pushed; it lands through the orchestrator after the cut.

## What was measured before (this tree at origin/main, binary built from it, 25/11 on avell)

`scripts/test-esc-stops-pty.mjs` (ESC_ONLY=bash), load 12.7-19.3:

* Esc -> usable prompt **794-909 ms**, the node's own stop **649-712 ms** - the row's budget is 300 ms
  idle / 120 ms per unit of load;
* the `sleep 30` was **still alive 1000 ms after the prompt** (the row's own bound) and ran to its end;
* the code-mode pending record said `{state:"running", reason:"run_cancelled", progress.elapsed_ms:1008}`
  while the operation's own record said `{"state":"accepted","settled":false}`: the stop answered the
  script and **never asked the node to stop the work**.

## What the diff does

**1. The stop asks first, and says what it took** - 1ef3865a
(`rust/wa-operation/src/process.rs`, `rust/wa-operation/src/lib.rs`, `rust/wa-operation/src/windows.rs`).
`Process::stop()` sends SIGTERM to the operation's whole process group, reaps the direct child while the
grace runs (an unreaped child keeps `kill(-pgid, 0)` answering "alive" about a corpse), KILLs what is left
after `STOP_GRACE_MS = 250`, and answers `Stopped {signal, grace_ms, needed_kill, survivors}`. The
supervisor uses it for a cancel or a deadline and keeps the abrupt kill for the two ends that are not a
stop (a shell that left descendants behind; this process going away). The operation's record carries
`stop: {signal, grace_ms, needed_kill, survivors}` (measured after this change: `{"signal":"TERM",
"grace_ms":250,"needed_kill":false,"survivors":false}`). On Windows the job object has no polite signal,
so the record says `JOB` rather than claiming a TERM it never sent - see "not proven".

A deadline goes through the same path, and that half has its own row - 0ae44a3c
(`rust/wa-operation/src/tests.rs`): `sleep 30` with a 300 ms deadline settles as `deadline_exceeded` with
`stop: {signal:"TERM", grace_ms:250, needed_kill:false, survivors:false}`, read from the record and not
from a sentence. It cannot pass on the base: that `stop` key is introduced by 1ef3865a.

**2. The wait wakes on the cancel** - 3e7211f7, corrected by 61230875
(`rust/wa-capabilities/src/operations.rs`, `rust/wa-capabilities/src/serve.rs`). The `wait` action sat in
one condvar timeout for the whole `wait_ms` the caller asked for - a second, from the code-mode layer - so
the stop landed wherever that second ended. It now waits in 25 ms steps (the same step the foreground loop
uses) and answers the operation's state as it stands with `interrupted: true` as soon as the run is
cancelled. `M.SLICE_MS = 1000` stays as it is: the slice no longer bounds the stop. The early answer is
restricted to a wait THIS node's interpreter is making (`serve::current_call_is_relayed()`): a relayed
`operation await` from a peer still answers at its own wait_ms, or it would report an interruption for work
nobody asked to stop (that is what `operations::adoption_survives_the_relay_deadline` pins, and it failed
until 61230875).

**3. The pending layer stops what the run started, and says so** - 2fe2fb47
(`lua/core/codemode_pending.lua`, `lua/core/codemode.lua`, `lua/core/agent.lua`, `lua/core/cli_view.lua`).
A cancelled call dispatches the operation's own `cancel` (or the peer's, through the peer's own operation
tool), reads the answer back for up to 120 ms, and records
`stop: {command, after_s, detached, confirmed, signal, needed_kill, survivors, note}`. The sentence travels
from the call's record to the run's tool context (`codemode.lua`, `cancel_error`), to the round that ends
the run (`agent.lua`, `stop_notice` - the cancellation is raised one round after the stopped call), and out
onto the reader's own line (`cli_view.lua`), after the code word every matcher looks for:

    Interrupted by user · stopped: sleep 30, after 0.4 s (nothing survived the 250 ms grace)

**4. Detached work is not the stop's to kill** - 2fe2fb47
A record is `detached` when the call STARTED that way: `wait_s: 0`, or anything the `operation` tool
started or attached to. It is never decided by how the call happens to be waited on now. For such a record
the stop signals nothing and says what is still running:

    still running: sleep 30, after 1.2 s (op op-…), left alone because it was started detached (wait_s:0, or the operation tool)

**5. Rows** - 67164002 (pty row), e394a463 (Lua rows)
* `scripts/test-esc-stops-pty.mjs`: both named known-fails are plain checks now (the shell is gone within
  1000 ms of the prompt; the bash leg is inside the budget - the budget was not moved), plus the sentence
  on the reader's line, the node's own record, and a new `detached` leg. **Wired in `scripts/fast.sh`**
  (the pty block: `WA_BIN="$bin" check esc-stops-pty node scripts/test-esc-stops-pty.mjs`); it is NOT in
  `scripts/test.sh` - the pty row has only ever run on the fast path and no change here moves it.
* `scripts/test-codemode-pending.lua` 11(d): the stop dispatches the cancel, the answer names the command
  and its runtime, the record is `cancelled` with reason `run_cancelled`, the pid the command wrote is
  gone (`kill -0` non-zero), and the already-detached handle keeps running with no signal recorded. Wired in
  the FAST PATH, which runs every `scripts/test-*.lua` not listed in `scripts/fast-path.exclude` (this row
  is not listed), each with its own scratch home; `scripts/test-codemode-component.sh` runs it on both the
  native and the component path (119 checks each, identical), as a standalone runner.
* `scripts/test-remote-pending.lua`: a stopped remote wait relays the cancel to the peer and the PEER'S OWN
  shell is gone afterwards (read from the pid the command wrote on the peer). Wired in `scripts/test.sh`.

## Measured after (same row, this tree)

| leg | usable prompt | node stop | shell gone | load |
|---|---|---|---|---|
| headers | 143 ms | 2 ms | - | 7.1 |
| stream | 143 ms | 2 ms | - | 7.1 |
| bash | 277 ms (232 ms in a second run) | 98 ms (88 ms) | **0 ms** | 6.7 (5.6) |
| detached | 188 ms | 42 ms | alive, by design | 6.3 |
| remote | 182 ms | 23 ms | - | 7.4 |
| subagent | 231 ms | 50 ms | - | 7.6 |

Full row: **32 ok, 0 failed** (six legs). The bash leg's own record:
`{"signal":"TERM","grace_ms":250,"needed_kill":false,"survivors":false}`, the note
`stopped: sleep 30, after 0.4 s (nothing survived the 250 ms grace)`.

## Checks run

* `WA_BIN=…release/wa node scripts/test-esc-stops-pty.mjs` (all six legs): 32 ok, 0 failed.
* `bash scripts/test-codemode-component.sh` (builds the codemode component, runs both paths): seam ok,
  pending handles 119 checks on each path.
* `scripts/test-remote-pending.lua`: 94 checks; `scripts/test-codemode-pending.lua`: 119 checks.
* `cargo test -p wa-operation`: 61 passed, 0 failed, 3 ignored. `cargo test -p wa-capabilities`: 411
  passed, 1 failed - `capabilities::tests::documented_inventory_matches_the_live_registry`, which fails
  because `run_state` is registered but undocumented in `docs/HOST.md`. **Pre-existing**: this branch does
  not touch `capabilities.rs` or `docs/HOST.md` (`git diff --stat origin/main..HEAD` lists neither), so
  the failure is the base's and is named here rather than fixed out of scope.
* **The new checks fail on the base** (a separate worktree of origin/main, these same test files, the same
  binary): the pty row gives `FAIL - bash: the shell the stop interrupted is gone…`, `FAIL - bash: the stop
  names the command it stopped…`, `FAIL - bash: the node's own record says how the group ended…`; the local
  row stops at `the stop names the command it stopped: nil`; the peer row at `and names the command it
  stopped, on the peer: nil`.
* **A healthy turn's request bytes do not change** (FACTORY rule 12): the same fixture bodies for the bash
  leg on the base tree and on this tree are byte-identical after normalising the two facts about the machine
  that differ - the checkout path and an operation id inside a tool result. No diff touches a prompt,
  envelope or schema file.

## Texts to approve (every new or changed operator- or model-facing string, verbatim)

1. `· stopped: <command>, after <n> s (nothing survived the <grace> ms grace)` - the reader's line after a
   stop whose group ended on TERM (grace = 250).
2. `· stopped: <command>, after <n> s (it did not end on the stop, so its group was killed after the <grace> ms grace)`
3. `· stopped: <command>, after <n> s (it did not end on the stop, so its group was killed after the <grace> ms grace; a process was still listed after the kill)`
4. `· stopped: <command>, after <n> s (the stop was requested on <node> and the node had not confirmed it gone within 120 ms)`
5. `· stopped: <command>, after <n> s (the node reports it ended; the record of how was already gone)`
6. `· stopped: <command>, after <n> s (its group was already gone when the stop arrived)`
7. `· stopped: <command>, after <n> s (the stop could not be asked for: <why>)`
8. `· stopped: <command>, after <n> s (this build has no stop for a <kind> call)`
9. `· still running: <command>, after <n> s (op <op id> on <node>), left alone because it was started detached (wait_s:0, or the operation tool)`
10. `· stopped: … (the job object ends every process at once; nothing was left)` and
    `· stopped: … (the job object was ended; a process was still listed after it)` - the Windows records.
11. The cancel error the run records carries the same sentence after its code word:
    `run_cancelled: stopped: sleep 30, after 0.4 s (nothing survived the 250 ms grace)`. Every matcher in
    the tree still sees `run_cancelled` first.
12. The operation record gains `stop: {signal, grace_ms, needed_kill, survivors}` (readable by
    `operation status`/`wait`), and the pending record gains `stop: {command, after_s, detached, confirmed,
    signal, needed_kill, survivors, note}`.
13. `docs/OPERATIONS.md` and `docs/CODEMODE.md`: the paragraphs added in 61230875 that state what a run
    cancel now ends and what it leaves running.

## Not proven / not done

* **Windows**: `Process::stop()` in `rust/wa-operation/src/windows.rs` is compiled only under
  `cfg(windows)`; it was not built or run on this node. Its contract is stated in the code (a job object
  ends every process at once, so the record says `JOB` and gives no grace).
* **A supervised child has no process group of its own** (measured this session, in the pty fixture):
  the child's OWN provider request arrives with `tools=[]`, so a child cannot run a shell and there is no
  child process group for a stop to end. A `subagent-bash` leg was written, measured exactly that fact, and
  removed: a check that cannot see a shell proves nothing (QUALITY RULE 1). What a stop does to a child -
  ending the run that awaits it - is unchanged by this branch.
* **The peer leg's relay is a stand-in**: `scripts/test-remote-pending.lua` runs the real peer half
  (`wa_peer_dispatch` → real operations → a real process group) and the real caller half, but the relay
  between them is an in-process stand-in, as that row has always said. The real relay's stamped deadline is
  exercised elsewhere, not here.
* **The pty row's remote and subagent legs do not stop a process group of their own**: the remote leg waits
  on a peer that never answers (no process to kill) and the subagent leg waits on a child whose provider
  call is held. The peer's process group is proven in `scripts/test-remote-pending.lua` instead. The
  subagent's own cancel path is unchanged by this branch.
* **The 120 ms confirmation window** is a read, not a guarantee: on a heavily loaded node the answer can
  say "the stop was requested and not confirmed within 120 ms" while the group dies a moment later. The
  sentence says exactly that instead of claiming a stop that was not observed.

## Premises in the brief that were wrong

* The brief put the quantisation in `lua/core/codemode_pending.lua:79 M.SLICE_MS` / `operation_poll`
  (`:375-390`). Measured: the Lua slice is only the outermost bound - the wait beneath it was ONE condvar
  timeout in the Rust `wait` action, which is where the 395-907 ms came from. `M.SLICE_MS` is unchanged at
  1000 and the stop no longer waits for it (3e7211f7).
* The brief names `/stop` as one of the stops. **Measured: there is no `/stop` command in this tree**
  (`lua/core/commands.lua`'s own table has `/wake cancel`, `/new`, `/undo`, ... and no `stop`), and steering
  does not cancel: it FENCES pending effectful calls (`steering_admit`, `lua/core/agent.lua`). The run-cancel
  sources that do exist - Esc and Ctrl+C in the CLI reader, a served run's cancel, a subagent's cancel, and
  a deadline - all reach `cancelled()` / `run_cancel_requested()`, so all of them now stop the work. If
  `/stop` is meant to exist, it is a MISSING COMMAND, not a missing stop.
* The brief says "the stop never signals the process group". The machinery existed and the *foreground*
  path already used it (`change/esc-stops-now`, 23/11); the turn's `bash` runs inside the code-mode pending
  executor, which returned `run_cancelled` to the script and never dispatched a cancel. That is what
  `reason:"run_cancelled"` next to `state:"accepted"` in the pending record shows.
* The brief's item 4 asks for "remote and subagent legs: the same checks". The pty row's remote and
  subagent legs have no process group behind them (see "not proven"); the peer's group is checked in the
  peer row, which is where a real peer process exists.

## How Victor tests it

Ask wa to run `sleep 300`, press Esc: the prompt is back at once, `pgrep sleep` in another window shows
nothing, and the line at the end of the run says
`Interrupted by user · stopped: sleep 300, after 2.1 s (nothing survived the 250 ms grace)`.
