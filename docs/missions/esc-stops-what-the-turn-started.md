priority: 1

# esc-stops-what-the-turn-started: ONE owner - Esc stops everything this turn started (joined chain, law 18)

This brief TAKES three:

- `esc-stops-now.md` (landed `365befbf`) - the PROVIDER WAIT
- `esc-stops-what-it-started.md` - the PROCESS GROUP
- `esc-socket-per-thread.md` - WHICH SOCKETS

All three are renamed `.taken-esc-stops-what-the-turn-started.md` in the queue. One sentence, one owner, one
number to be judged by.

## Why they cannot be three

Each brief was a true claim about one sentence, and each was written against the other two being solved:

| brief | what it owned |
|---|---|
| esc-stops-now | a foreground model call that gets no bytes ends on Esc, not on the provider's next line; the partial answer stays and is marked interrupted; a cancel is not a retry; a silent call does not look dead |
| esc-stops-what-it-started | the shell the turn started is TERMed/KILLed by its process group, not only left behind a returned prompt; the wait wakes ON the cancel and not at the next 1 s slice (`lua/core/codemode_pending.lua`, SLICE_MS = 1000; measured 395-907 ms); a detached command survives; the answer names what was stopped |
| esc-socket-per-thread | `FOREGROUND_SOCKETS` is ONE process-wide slot and `clear_active_socket()` wipes it, so in `wa serve` - or a CLI with a relay poll - one call finishing unregisters the model stream's socket, and Esc shuts down sockets that are not the run's |

The three fail together in the only situation that matters:

1. **"the run's sockets" is only a fact once the slot is per call.** esc-stops-now shuts a socket that
   esc-socket-per-thread says may belong to somebody else. Fixing the wait without the slot makes the stop
   *fast and wrong*.
2. **the process group is only stopped if the wait wakes on the cancel.** The 1 s poll slice is that same
   wait: a brief that shortens the prompt without touching the slice leaves Esc returning to a prompt while
   `sleep 300` still runs.
3. **300 ms is one number, and it is the person's.** Each brief could pass its own leg while the person
   still waits (that is exactly the 21:15Z incident: the prompt came back and the command did not).

Two of the three were priority 1 and one was priority 2, so as separate briefs the cheapest could land on a
path the other two then contradict. This file is the join: one claim, one chain, one set of tests.

## The claim

After Esc - and after every stop: `/stop`, a steer that cancels, a turn's deadline - the person has a usable
**prompt within 300 ms warm**, and at that moment:

1. a provider wait in flight has ended without waiting for a byte (headers wait, silent stream, mid-stream);
2. the command the turn started has its **whole process group** TERMed, then KILLed after a stated grace, and
   the answer says what was stopped and whether anything survived it;
3. a command the turn started **detached on purpose** is still running, and the answer says so;
4. a second HTTP call in the same process that is **not** the run's is **not** torn down;
5. the partial answer stays on screen, marked interrupted; the ledger has one `input|interrupt` row with the
   host's clock for the keypress;
6. a cancel is **never** logged as a provider retry;
7. a silent call does not look dead: while a model call has produced no byte the status row counts it
   (`waiting for the model - 12s - esc to stop`), and a cold context says the first reply will be slower.
   Display only: nothing the model reads changes, the request bytes are identical (probe).

**Not in this claim:** the prompt's own redraw cost, and anything the person does not press Esc on.

## Measured on main first

**`scripts/test-esc-stops-pty.mjs --measure`, tree `77bcaa23` (main), this laptop, load 7.45-7.91 at the
key.** Binary `/home/victor/wasm-agent/target/m-capability-registration-is-data/release/wa`: its tree's `rust/`
is identical to main's (the branch it was built on names no rust file against `origin/main`), and the budget
below is the row's own - 300 ms idle plus 120 ms per unit of run-queue load.

    scenario   usable (pty)  node prompt  stop (node)  settle  load   shell gone
    headers    150 ms        26 ms        3 ms         11 ms   7.45   -
    stream     154 ms        34 ms        2 ms         15 ms   7.89   -
    bash      1098 ms       949 ms       922 ms       14 ms   7.90   NOT GONE (1 alive)
    remote     188 ms        43 ms        23 ms       10 ms   7.91   -
    subagent   225 ms        80 ms        44 ms       10 ms   7.52   -

Row verdict on main: **21 ok, 0 failed, 2 known-fail**, both known-failures on the BASH leg:

1. the stop is quantised to the code-mode executor's 1 s poll slice (`lua/core/codemode_pending.lua:79`
   `M.SLICE_MS = 1000`; `operation_poll` :375-390 asks `cancelled()` only between slices) - 395 ms just
   before a boundary, 907 ms just after, measured 1098 ms usable at load 7.9 against a 948 ms budget;
2. the shell outlives the prompt - 1 process still alive 1000 ms after the prompt, and it runs to its own end.

What the baseline says about the three taken briefs, which is the reason for joining them:

- **the provider wait is already inside the budget on main** (headers 150 ms usable / 3 ms of stop; silent
  stream 154 ms / 2 ms), and the same run shows the interrupt row, the absent provider retry and the
  display-only status row green. That is `esc-stops-now`'s landed work, measured rather than assumed.
- **the process group is not done**, and it is the only leg outside the budget. The 1 s slice and the
  unkilled shell are the same wait: fixing one without the other buys a prompt that returns faster to a
  command that still runs.
- **the socket identity has no row on main at all**: nothing in this fixture runs a second HTTP call beside
  the run's, so the process-wide `FOREGROUND_SOCKETS` slot can be wrong today with every test green. That is
  why M1 adds that case before anything touches the wait.


## The chain (each step names the test that is red before it and green after)

Ordered so that no step can be "green" by shutting the wrong socket or by betting on a slice.

**M1 - the slot is per call.** Registering and clearing touch only the caller's own socket
(`rust/wa-capabilities/src/host.rs` `FOREGROUND_SOCKETS` / `clear_active_socket()`).
Test: pty case `Esc while a second HTTP call is in flight` - the run stops inside the budget and the other
call is still answered (red on main: the other call is torn down).

**M2 - the provider wait ends without a byte.** The foreground call registers in that slot and the interrupt
shuts it; the same for a wait on response headers and for a silent stream.
Tests: the `headers` and `stream` legs inside 300 ms, and the partial answer kept.

**M3 - the wait wakes ON the cancel.** `operation_poll` waits on the cancel instead of between 1 s slices
(`lua/core/codemode_pending.lua`).
Test: the `bash` leg inside 300 ms (red on main: 395-907 ms).

**M4 - the stop signals the process group.** TERM to the group, KILL after the stated grace, the answer names
what was stopped, and a detached command is left alone.
Tests: the row's two named known-fails become real checks - the `sleep 30` is gone within the stated bound,
and the detached server survives; a new check that the answer says what it stopped.

**M5 - the record and the display.** One `input|interrupt` ledger row stamped from the host's clock; no
`provider_retry` for a cancellation; the status row counts a silent model call.
Tests: ledger rows, singly (red on main).

**M6 - the other two legs get the same treatment.** `remote` (a stop on a peer stops the peer's process
group) and `subagent` (the child's own wait) are checked against the same 300 ms and the same "what was
stopped" text.

## How Victor tests it

Ask wa to run `sleep 300`; press Esc: the prompt is back at once and `pgrep sleep` in another window shows
nothing. Ask something, press Esc within a second: the prompt is back at once. Leave a long session idle for
an hour, ask again: the status row counts the wait and Esc still stops it at once.

## Rules

- **Touches what a turn's stop does and everything the person and the model read**: the diff and every text
go to the orchestrator (Fable) BEFORE landing. `scripts/test-esc-stops-pty.mjs` is the row of record; its
budget is stated per unit of run-queue load (the row already measures the machine, not only the code).
- No release, no fleet, no key retirement, nothing on a live peer (scratch nodes only). Never touch
  `~/.wasm-agent/graph.db.malformed-20261122T144358Z` (evidence). FACTORY rule 12: never install into
  `~/.local/bin` or edit `installed.txt`.
- **Suite rule** (Victor's standing rule: a landing runs no gate): run ONLY the rows for the files touched
  (`flock -o ~/Work/missions/.suite.lock env WA_FAST_ROWS=<file of row paths> bash scripts/fast.sh`), plus
  `scripts/test-host-return-docs.lua`, the prompt tool-name row and the prompt-docs check when a tool or
  capability description or `docs/HOST.md` is touched, plus the new tests singly.
- The factory's scripts (`~/Work/missions/*.sh`, `_orch/`, `~/.local/bin`, systemd units) are OUTSIDE this
  tree: never edit them; propose a diff in the report instead.
- Propose (never write) `FACTORY.md` / `HANDOVER.md` text in the report.

## Notes found while measuring (proposed, not changed)

- **main's rust workspace has no members.** `rust/Cargo.toml` is 27 bytes - `[workspace]` and
  `resolver = "2"` - since `26dcbb41` ("re-land wa-term-own-program on the current main, with the publish build
  fixed", authored `row <row@example.invalid>`), which deleted the 50-member `members = [...]` line. A build
  from the canonical checkout therefore compiles nothing (`cargo metadata`: `packages: []`), and
  `scripts/deploy.sh`'s `--manifest-path rust/Cargo.toml` build has nothing to build. The baseline above was
  measured with a binary whose rust sources are main's, and the workspace was not touched by this brief: the
  repair belongs to whoever owns the tree's manifest, and the diff is one line (`members = [...]` restored from
  `9eb8f9f7:rust/Cargo.toml`).
