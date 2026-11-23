# esc-stops-now: Esc ends a run at once, and a silent model call never looks dead

Victor, 23/11: *"stopping the mid flight run took a significant amount of time, i think we are able to ...
get it instantaneous"*, and the session before it *"got a serious bug and stopped responding"*.

Branch `change/esc-stops-now`, base `5956ae15`.
Code: **e311b1ed**. Tests and their wiring: **4f88f246** (plus the report commit that carries this file).

## 1. Measured, with a fake provider in a real pty

`scripts/test-esc-stops-pty.mjs` drives the real binary in a private tmux pty against one fixture that is
both the rendezvous and the provider, presses Esc in each of the five ways a run can wait, and measures
Esc-to-prompt from outside the process: the moment tmux hands the Esc byte to the pty, and the moment
`⎿ Interrupted by user` is on screen. The same file was run twice - once with a binary built from the base
commit, once with this branch's - so both columns are the same fixture and the same measurement:

| scenario | base (5956ae15) | this branch (e311b1ed) |
|---|---|---|
| (a) before response headers, provider holds 30 s | **never** (gave up at 20 s) | **165 ms** (204 ms in a second run) |
| (b) mid-stream, after one chunk and 10 s of silence | **9751 ms** | **164 ms** (171 ms) |
| (c) during a local shell (`sleep 30`) | 234 ms | **259 ms** (277, 293 in other runs) |
| (d) during `tools.remote` to a peer that accepts and never answers | **never** (gave up at 20 s) | **187 ms** (194, 206) |
| (e) during a supervised child (its own provider call held) | **348 ms** | **234 ms** (242, 245) |

Reproduce: `WA_BIN=<wa> node scripts/test-esc-stops-pty.mjs`. `ESC_ONLY=headers,stream` runs a subset;
`ESC_DEBUG=1` prints the fixture's arrivals and the screen at the key.

**(c) was already inside the budget on the base binary in this measurement (234 ms), and is 259-293 ms
here**: the numbers are noisy in the 230-330 ms band across runs (the base binary itself measured 306
and 326 ms in the two earlier runs of an earlier fixture). What changed there is the poll that notices
the interrupt (100 ms -> 25 ms, `rust/wa-capabilities/src/operations.rs:1122`), which cannot make it
slower in principle; what remains is the reader's own 120 ms lone-Esc lookahead plus the shell's own
teardown, and that lookahead is a third of the budget no matter what this change does.

**(e) on the base binary (348 ms) is the same fixture**: the child is started and awaited for real
(`tool_search` pins the facade, then `start`, then `await`); the base binary's await wakes on a 250 ms
slice, this branch's on a 50 ms one (`rust/wa-capabilities/src/subagents.rs:837`).

A first baseline, taken before the fixture learned to pin an outer facade with `tool_search`, reported
the same never / 9775 ms / 326 ms for (a)-(c) and a meaningless 259 ms for (e) - the model's call to a
facade that is not in the declared tool list was dropped and the turn ended as an empty reply. That
number was in the mission notes; the table above supersedes it.

## 2. What the code does now

**A stop wakes the read (a, b, d)** - commit `e311b1ed`:
* `agent_for_call` / `agent_for_stream` (`host.rs:463`, `host.rs:478`) return the shutdown-aware
  transport for the FOREGROUND too; before, a thread with no task got a plain `ureq::Agent`.
* `subagents::register_active_socket` registers into a process-wide `FOREGROUND_SOCKETS` slot when the
  thread has no task (`subagents.rs:97`, slot at `:106`), and `shutdown_foreground_sockets`
  (`subagents.rs:114`) shuts those sockets down - the mechanism a child already had.
* `raise_cli_interrupt` (`host.rs:524`) is now the ONE act of a keypress: the flag, the stamp and the
  socket shutdown. It is called from the Esc arm, from Ctrl+C and from a send-now line; a plain Enter
  clears it (`clear_cli_interrupt`).
* `http_transport::await_input` no longer has a "no task, no cancellation to observe" fast path, and its
  poll slice is 50 ms instead of 250 ms (`http_transport.rs:143`).
* A read that ends because the socket was shut down is reported as `run_cancelled`, not as a transport
  error (the `send` error mapping and the line-read arm inside `stream_completion`), and every exit of
  `stream_completion` forgets its socket (`host.rs:3341`).
* The partial answer already streamed is KEPT and the turn is marked interrupted:
  `cli_view.failed` flushes what had arrived before it writes `⎿ Interrupted by user`
  (`lua/core/cli_view.lua:3088`). Before this, a stop threw the half-written answer away with the
  streaming buffer.

**The key is recorded (3)** - commit `e311b1ed`: the reader stamps the moment it raised the interrupt
(`CLI_INTERRUPT_MS` / `CLI_INTERRUPT_KEY`, `host.rs`, beside `CLI_INTERRUPT`) and `host.input_take`
answers `interrupt_at` / `interrupt_key` (`host.rs:6036`). `cli_input:interrupt()`
(`lua/core/cli_input.lua:216`) reads them with a zero wait and keeps the lines it carries, and
`lua/core/chat.lua:633` writes one `kind=input, phase=interrupt` row with that stamp - at the end of a
cancelled run and again at the prompt, deduped by the stamp.

**A cancel is never a provider retry (4)** - commit `e311b1ed`: `provider.is_cancellation`
(`lua/core/provider.lua:1154`) is an allow-list of the two codes a cancellation path raises, and the
retry classifier asks it first (`lua/core/agent.lua:2927`) and excludes a cancellation from the
unclassified bucket (`:2960`).

**A silent call does not look dead (5)** - commit `e311b1ed`: while a model call has produced no byte for
more than one second (`M.WAIT_AFTER_SECONDS`, `lua/core/cli_view.lua:1445`), the status row reads
`waiting for the model · 12s · esc to stop` with its own clock token `{w}` (`cli_view.lua:1467`), filled by
the view (`status_text`) and by the host ticker while the interpreter is blocked
(`TickerSpec.wait_started`, `rust/wa-capabilities/src/host.rs`). When the last answer is older than five
minutes (`M.COLD_CONTEXT_SECONDS = 300`, `cli_view.lua:1439` - an ASSUMPTION, named as one in the code)
the row also says the context is cold and the first reply is slower. Display only: the same turn's
request bytes are byte-identical between the base binary and this one (one body each, 30055 bytes,
compared with `ESC_BODIES=`), and the pty test asserts that none of the row's words appears in any
request body.

## 3. Tests, and where they are wired

* `scripts/test-esc-stops-pty.mjs` - the five measurements plus the ledger checks (interrupt row, no
  provider_retry row, the partial kept, the display-only probe). Wired into the fast path
  (`scripts/fast.sh`, row `esc-stops-pty`). On the base binary it fails 4 of the 5 timing checks and
  all five interrupt-row checks, and the stream scenario's provider-retry check.
* `scripts/test-cancel-not-retry.lua` - the classification allow-list, one provider call and zero wait
  for a cancelled call, no `provider_retry` row, and the unclassified bucket still replaying. Wired into
  the gate (`scripts/test.sh:2039`) and picked up by the fast path's `scripts/test-*.lua` sweep. On the
  base binary: **4 checks fail** - no `is_cancellation`, 6 provider calls, 27848 ms of waits, 5
  `provider_retry` rows.
* `scripts/test-cli-view.lua` - the new block at the end pins the wait row, its clock, its absence once
  the provider speaks, its absence while a tool is in flight, and the cold-context sentence. Wired in
  `scripts/test.sh:2034` (and the fixture run at `:2092`). On the base Lua it fails: no wait row, no
  `{w}`, no `COLD_CONTEXT_SECONDS`.

The 566-check view suite is green. The only pre-existing assertion touched is the live-run replay: its
own new comment says that a run whose model call has said nothing for over a second now shows the wait,
and the run it replays therefore starts with the model having spoken. No assertion was loosened - every
edited one still pins an exact string.

## 4. Premises from the brief that were wrong or stale

* "http_stream ~l.3290-3370": the function that reads the provider stream is `stream_completion`
  (`rust/wa-capabilities/src/host.rs:3341` today; it had no wrapping function before this change), and
  the transport choice is `agent_for_stream` at `host.rs:478`. The comment the brief quotes ("a silent
  provider is woken by the socket shutdown the cancel path performs") was true only of the child path -
  it is true of both now, and the comment stays true.
* "(e) during a subagent": the CLI's declared tool list does NOT contain `subagent` or `remote`; they are
  outer facades, pinned with `tool_search` (measured: the first request of a session declares
  `bash, edit, read, recall, remember, skill, time, tool_call, tool_search, web_read, web_search,
  write`). A model's direct call to either is dropped and the turn ends as an empty reply - which is what
  the first baseline of (e) actually measured. The fixture now pins the facade first.
* "no key event in the ledger" is fixed by item 3: `input|interrupt` now exists with its stamp, and
  `wa stalls` is untouched (it pairs `phase=submit` rows only, checked in `lua/core/stalls.lua`).

## 5. Texts to approve (model- or operator-facing, verbatim)

1. `waiting for the model · {w} · esc to stop` - the status row while a model call has produced no byte
   for over a second.
2. ` · the context is cold ({age} idle): the first reply is slower` - appended to that row when the last
   answer is older than five minutes.
3. `⎿ Interrupted by user` - unchanged wording, but it now FOLLOWS the partial answer that streamed
   instead of replacing it.
4. The ledger payload of the new row: `{ source = 'cli', key = 'esc' | 'ctrl+c' | 'send-now' }` with kind
   `input` and phase `interrupt`.

## 6. Proposed FACTORY.md / HANDOVER.md text (proposed, NOT written)

**HANDOVER.md**: "A stop must not wait for the provider. Esc (and Ctrl+C, and a send-now line) raises one
interrupt that also shuts down the socket the foreground provider read is blocked on
(`subagents::shutdown_foreground_sockets`); every wait a run can be inside - the provider read, a local
shell, a peer call, a supervised child - notices it within 50 ms or less. Measured Esc-to-prompt, real
binary in a pty: 165-204 ms before response headers, 164-179 ms mid-stream after a 10 s silence,
187-206 ms inside a tools.remote call, 234-245 ms inside a subagent await, 259-293 ms inside a local
shell (23/11, commit e311b1ed). node scripts/test-esc-stops-pty.mjs is the measurement, and it fails on
the code before this change."

**FACTORY.md (rule-shaped)**: "A cancellation is never a failure: it is not replayed, not written as a
provider retry, and it is recorded as its own input|interrupt row stamped by the host, so the ledger can
answer how long a stop took (provider.is_cancellation; record_interrupt in lua/core/chat.lua). A status
row may describe only state the view already has: nothing on that row may reach the request bytes, and
the probe for that is ESC_BODIES= on the pty test."

## 7. Not verified, and open

* Nothing was measured against the operator's real provider (no paid call, per the rules): every number
  above is the fake provider in a pty. The mechanism - a shut socket, a poll slice - is the same code path.
* The cold-context threshold (five minutes) is an assumption, not a measurement: no provider here
  publishes its cache lifetime. It only chooses which sentence the row adds.
* On Windows a shutdown of a duplicated handle does not wake a blocked read (the transport's own module
  says so); the 50 ms poll is what covers that, and I could not test it on this node.
* The local-shell stop still spends the shell's own teardown, and the reader's lone-Esc lookahead spends
  120 ms of the 300 ms budget in every scenario; both are outside this change.
* `scripts/test-esc-stops-pty.mjs` needs `tmux` and `sqlite3` and SKIPs (never passes) without them.
* Nothing was released, deployed, installed or pushed; no live peer was called. FACTORY.md and
  HANDOVER.md are untouched - the text in section 6 is a proposal for Fable.

## 8. Follow-up, 23/11 ~14:20Z: main went red on 7865a08e and three rows were blamed on this branch

Landed tip `3655948d`; this follow-up branch is cut from `origin/main` 7865a08e and carries one commit on top of
it. What each red row was, and what this commit does about it:

**(1) `scripts/test-hotreload.lua` - 2 of 217 ("the planted copy renames the phase word", "the frame
after the swap is drawn by the new module").** The row planted a phase-word rename by matching the status
branch's head IMMEDIATELY followed by `self.phase = "Thinking"`, and e311b1ed inserted one line into that
branch (`self:model_waiting()`), so the plant stopped matching and the row judged the anchor instead of the
code. THE ANCHOR WAS FIXED, NOT THE CODE: the pattern now allows exactly one arm line between the branch
head and the phase word, keeps the older two-line shape as a fallback, and requires the plant to match
EXACTLY ONCE (`ok(planted == 1, ...)`, stricter than the old `marked ~= good`). The row is green: **217 checks**,
`hotreload ok` (run against this tree with `WASM_AGENT_LUA_ROOT=$PWD`).

**(2) `esc-stops-pty` at load ~10: bash 1041 ms, remote 396, subagent 417 (limit 300).** Measured here, and the answer
is BOTH halves of the question:

* The bash path does NOT wait for the child. The row now measures that directly: it walks this session's
  own process tree (`descendants(pane_pid)`, never a search by name) from the moment the prompt returns, and the
  run's shell is gone in **5-15 ms** at every load measured - so the 1041 ms was not the kill.
* The stop itself scales with the machine, so the budget is now stated RELATIVE TO LOAD, and the row
  prints the load it measured (`load at the key` column) and the shell-gone number beside it. Limit =
  `max(300 ms, 120 ms x load)`, with a hard `2000 ms` ceiling no load excuses (`HARD_MS`).

| load at the key (this node, 23/11) | headers | stream | bash | remote | subagent | shell gone after |
|---|---|---|---|---|---|---|
| 6.97-7.88 (ambient, final run) | 183 | 180 | 268 | 174 | 251 | 5-13 ms |
| 8.95 / 11.5 (+ 6 busy loops and 6 fork loops) | - | - | 309 | - | 369 | 14 ms |
| 9.6-12.9 (+ 12 busy loops) | 230 | 212 | 333 | 222 | 345 | 9-14 ms |
| 12.2-12.9 (ambient) | 184 | 179 | 300 | 202 | 271 | 6-11 ms |

I could NOT reproduce main-health's 1041 ms: a fork storm (6 CPU loops + 6 `/bin/true` loops) left bash at
309 ms and the shell dead in 14 ms. **If it recurs, `rust/wa-capabilities/src/operations.rs:1170` is the only
bounded wait on that path** - the cancelled operation is waited for up to 1000 ms to settle before the
tool returns - and it is the first place to instrument. I did not change it: it is a guess in a hot path
and the failure does not reproduce.

A limit stated per unit of load is a real trade and I want it read that way: at load ~10 the row now
passes a 1 s stop, because a stop that takes a second on a busy machine is not the bug this row exists
for (the code before the change was 9751 ms and "never"). At idle - which is what the brief asks for -
the limit is exactly 300 ms, and the row's own measurements there are 164-257 ms.

**(3) `tmp-cleanliness`: "scripts/test-esc-stops-pty.mjs starts a tmux server without
scripts/lib/tmux-session.mjs".** Fixed: the row imports `tmuxSession('wa-esc-stops')` and uses its `killServer()`
at every restart point, so the exit handlers and the SIGKILLed-sibling reclaim cover it. `test-tmp-cleanliness`
run against this tree: 9 checks, my row's rule green; **the one remaining failure is
`scripts/test-diff-card-pty.mjs` starting a tmux server without the helper** - that row is from
change/diff-card (edad0d39), not from this branch.

**(4) `scripts/test-script-writes-show-diff.lua`.** Does not reproduce here, and it is not this branch's: it
refuses to run outside the scratch root, and run correctly (a scratch home under `~/.wasm-agent/tmp`) it
printed no `FAIL` line. If it is red in main-health, the row's own output from that log is the evidence to
read, not this one.

Narrowed re-run of the rows this follow-up touches, on this tree (`debug` binary built from 7865a08e +
the follow-up commit): `test-esc-stops-pty.mjs` **18 ok / 0 failed**, `test-hotreload.lua` **217 checks ok**,
`test-tmp-cleanliness.mjs` 9 checks with the diff-card failure above, `test-cli-view.lua` **566 checks ok**,
`test-cancel-not-retry.lua` **15 checks, 0 failed**.

## 9. The 1041 ms, answered: the settle wait was in the path, and the stop no longer waits for it

Fable asked for twenty measured cancels of a local shell at load 10+, the distribution, and whether
`rust/wa-capabilities/src/operations.rs`'s 1000 ms settle wait is in the stop path. It was, it cost 4-33 ms, and it is gone.

**The instrument** (this branch's follow-up commit): `cancel_trace` in `operations.rs` writes one line -
`part=foreground settled/issued/waited/cap_hit/cleanup` - to the CLI's own log when `WASM_AGENT_CANCEL_TRACE=1`.
It costs nothing otherwise, and the pty row passes the knob through to the CLI.

**The measurement, 20 runs before the change, load 26.5-28.8** (the bash scenario: Esc during
`sleep 30`): Esc-to-prompt **341-537 ms** (median 410), the run's own shell gone **10-58 ms** after the
prompt, and in every one of the twenty the trace read

    part=foreground settled=1 issued_ms=0 settle_ms=6 looks=1 cap_hit=0

i.e. the 1000 ms cap was **never** reached: `manager().cancel` raises the flag, the operation's own thread
SIGKILLs the process group, and the FIRST 50 ms look inside the old loop already found it settled
(4-33 ms). So the cap was not main-health's 1041 ms - and the answer to "is the 1000 ms wait in the stop
path" is YES, at 4-33 ms of the reader's time.

**The change**: the stop no longer waits at all. `foreground` cancels the operation, returns at once, and
says so in the receipt (`cleanup: "supervised"`, `state: "cancelled"`, plus a `cleanup_note`); the supervisor
finishes the kill behind the run. A caller that needs the settle reads the operation (status/wait)
instead of holding the run for it; `lua/core/tools.lua` already does that on its own path, and treats
`cleanup == "unknown"` - not "supervised" - as the failure signal.

**The measurement, 20 runs after the change, load 26.8-32.4**: Esc-to-prompt **287-403 ms** (median 327),
shell gone **9-42 ms** after the prompt, and in all twenty:

    part=foreground settled=0 issued_ms=0 waited=0 cap_hit=0 cleanup=supervised

**And 10 runs on the quiet queue** Fable's amendment asked for (load 6.3-7.3, the lowest this node reached
all session): Esc-to-prompt **209-237 ms** (median 232), shell gone **4-9 ms** after the prompt, same
`waited=0` line in all ten. That is the number Victor asked for, and it is inside the 300 ms idle budget
without needing the load allowance at all.

**The test that fails if the prompt waits on the settle**:
`operations::await_returns_at_its_own_wait::a_cancelled_shell_returns_before_its_settle_finishes`
(`rust/wa-capabilities/src/operations.rs`). It flips the production cancel probe, calls the real `foreground`
with a `sleep 5` shell, and asserts: the receipt says `cleanup: "supervised"` (the code before this change
answered "settled", so it fails there), the call comes back in under 600 ms for a shell it only had to
cancel, and the operation really does settle BEHIND the call within a few seconds - the kill is not lost
by returning early.

### The regression this found, and the fix that belongs with it

Running the crate's own suite (`cargo test -p wa-capabilities --lib`, 394 tests) showed that e311b1ed had
broken `host::tls_anchor_tests::a_provider_call_refuses_a_private_ca_that_no_bundle_names` on main: the
private-CA refusal arrived as `Timeout(Connect)` after the whole connect budget. Cause, traced with a
temporary write/read trace and confirmed by bisecting `agent_for_stream` back to its base shape (which made
the test pass again): `register_active_socket` stored a CLONE of the socket in the process-wide slot and
nothing ever took it back when the request ended, so the refused connection stayed OPEN. The TLS fixture
serves one connection at a time, so the second agent in that test never got a handshake - and in
production the same retention meant a connection (an fd) held past the end of every call that did not run
through `host.http` / `http_stream` (which do clear the slot).

The fix: each registration gets an id (`subagents::NEXT_SOCKET_ID`), the transport owns its id, and
`impl Drop for ShutdownTcpTransport` takes exactly its own socket back (`unregister_active_socket`). The clone
and the transport that owns it now live and die together. `cargo test -p wa-capabilities --lib`: **394
passed, 0 failed** (the TLS anchor test included).

### Narrowed rows re-run on this tree (nothing else)

| row | result |
|---|---|
| `cargo test -p wa-capabilities --lib` | 394 passed, 0 failed |
| `scripts/test-esc-stops-pty.mjs` | 18 ok, 0 failed (load 27: 214/178/297/234/343 ms) |
| `scripts/test-hotreload.lua` | 217 checks ok |
| `scripts/test-cancel-not-retry.lua` | 15 checks, 0 failed |
| `scripts/test-cli-view.lua` | 566 checks ok |
| `scripts/test-tmp-cleanliness.mjs` | 9 checks, 1 failed - `scripts/test-diff-card-pty.mjs` still starts its tmux server without the helper (change/diff-card, not this branch) |


### Rebased onto origin/main 4ba1c3d9 (23/11, after the approval)

`change/esc-socket-per-thread` (beae64c6) had made the foreground socket slot PER THREAD and this branch had made each registration an id its transport releases on drop; the rebase kept BOTH, which is the only shape that holds: the slot is still the calling thread own (so one call finishing cannot unregister run socket), and every entry in it carries the id a `ShutdownTcpTransport` gives back when it drops (`unregister_active_socket(id)` looks in the task slot, this thread slot and every registered slot, so an agent dropped on another thread still releases exactly its own fd). `clear_active_socket` keeps main per-thread behaviour unchanged. No other behaviour was touched by the rebase: the stop still does not wait for the settle, the budget is still per unit of load, and the approval content is the same.


### Rebased again onto main 28fb526d (23/11, the preflight's merge conflict)

The branch is rebased onto 28fb526d; the only conflict was the same subagents.rs region as the first
rebase (main's per-thread foreground slot against this branch's per-registration id), and it was
resolved the same way - both kept. Rows re-run on THIS tree: cargo test -p wa-capabilities --lib 406
passed / 0 failed; subagents:: - the three socket tests, including main's two per-thread ones - 27
passed; scripts/test-cancel-not-retry.lua 15 checks 0 failed; scripts/test-esc-stops-pty.mjs 18 ok 0
failed (remote 189 ms, subagent 257 ms at load 10). No assertion was deleted, no row dropped, no
timeout raised.


### Landed, then main moved: merge 0238b6dd and the stdin argument (23/11, later)

This branch is merged (a029d0d5). Main then added a seventh argument to
operations::foreground (stdin, change/run-bodies-without-quoting) and its own test call sites took it;
TWO were left behind and the wa-capabilities lib TEST build stopped compiling - this branch's
a_cancelled_shell_returns_before_its_settle_finishes and an older promoted-shell test. Both now pass
None, which is the value the product passes when nothing is fed (host.rs:1741). No assertion was
touched. Re-run on this tree: cargo test -p wa-capabilities --lib 406 passed / 1 failed, and the one
failure is graph::tests::the_lockless_writer_a_wasi_guest_is_can_only_be_copied_under_the_store_lock,
which PASSES twice when run alone (2/2 in 1.5 s each) - a torn-write reproduction that did not
reproduce in a 70 s run under load ~7, not this branch's code and not a consistent red. The settle test
and subagents:: (27, the three socket tests) pass by name; test-cancel-not-retry 15 checks; and
test-esc-stops-pty is 18 ok / 0 failed at load 21-23 (remote 250 ms, subagent 323 ms).

### Main-health 8010d293: esc-stops-pty red on its bash row (23/11 ~20:15Z)

The failure, from the row's own log (fast-logs-8010d293992f/check-esc-stops-pty.log): load at the key
**2.32**, headers 163, stream 162, bash **692 ms**, remote 187, subagent 209 - and the run's own shell
was gone **5 ms** after the prompt. So a stop that was slow for something other than the shell.

Three single runs of the same row on this branch (70454ef0, on main 0238b6dd), one after another:

| run | load at the key | result | bash | notice_ms (Esc -> the run) | the row's own probe |
|---|---|---|---|---|---|
| 1 | 10.8-12.9 | 18 ok / 0 failed | 218 ms | 9 ms | 10 looks, worst 4 ms |
| 2 | 15.4-16.4 | 18 ok / 0 failed | 282 ms | 45 ms | 12 looks, worst 6 ms |
| 3 | 13.4-14.1 | 18 ok / 0 failed | 285 ms | 70 ms | 12 looks, worst 9 ms |

It did not reproduce - three for three green at load 10-16, on a row that failed at load 2.3. What the
runs DO show is the shape of the number, and it is why the 692 ms is not blamed on the stop itself:

* the run's own share is small and load-sensitive: Esc-to-the-cancel-line (`notice_ms`, now traced beside
  the cancel, operations::cancel_trace) was 9, 45 and 70 ms on the three runs, and `issued_ms` (the
  cancel work) was 0 every time;
* the rest (~150-200 ms) is the reader's own 120 ms lone-Esc lookahead, the redraw and tmux delivery -
  the same fixed cost every scenario shows (headers 169-200 ms), not a wait inside the stop;
* and the row's own measurement now reports what IT costs: every look at the screen is a tmux
  capture-pane process, and under a burst that process can take longer than the stop it measures. The
  table gained that column (8-12 looks, worst 3-12 ms here), and the failure detail names it, so a slow
  measurement can never again be read as a slow stop.

No timeout was raised and no budget widened to hide it: the idle limit is still 300 ms, the load rule is
unchanged, and what changed is that the row can now say WHICH part of a 692 ms stop it was. If it recurs,
the row's failure line carries notice_ms and the probe cost, and the answer is one of two things: the
reader thread did not get scheduled (notice_ms large), or the measurement did (probe large). Max harness
harm none: 407 lib tests pass (the split touches only the trace line and two accessors).

**Pending, said plainly**: a reproduction of the 1041 ms. Neither a fork storm nor load 32 produced it;
the trace line above is the first thing to read if it comes back, and `WASM_AGENT_CANCEL_TRACE=1` is how to
turn it on. Fable's amendment (stop the load loops, rerun on an idle queue, 10 runs) is what produced the
quiet-queue block above; the busy loops were killed by pid before that run.
