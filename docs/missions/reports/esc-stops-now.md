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
