# chat-start-guard

A turn's row is on screen within a second of the reader's Enter, the fresh reads a chat makes happen off
the interpreter's thread, and `wa stalls` measures from the keypress the host saw. Branch
`change/chat-start-guard`, base `a9d4617d`.

## What was wrong, and where it is fixed

| defect | fix |
| --- | --- |
| A turn's start asked the network before `run_started` drew anything (roster probe 20 s per offline peer, provider limits 4-7 s). Fixed by hand on 22/11 in `8082b42e`, unguarded by any test. | the pty test in `d7efc26e` (`scripts/test-chat-start-pty.mjs`) |
| The same two reads then ran at the idle prompt IN the interpreter, so an Enter pressed meanwhile waited for them. Measured on `a9d4617d`: 4.8 s of silence after Enter with a limits stub answering after 5 s. | `a651ea2e`: the views are built by `wa idle-reads` under `host.operation` (`lua/core/idle_reads.lua`) and applied on a later tick; the limits are read only where they are asked for |
| `whatsapp.service_row{cache_only=true}` called `federation.catalog()` twice, which refreshes from every online peer: measured 122 s of a blocked `/mcp` build for a peer that accepts and never answers - inside a call whose promise is that a snapshot waits for nothing. | `a651ea2e`: `cache_only` answers both fleet questions from `federation.cached()` |
| `wa stalls` measured a turn from its own `run/start` row, so a wait BEFORE the run was invisible (the operator's 20 s waits reported as 0.00 s), and its "worst five" were the last five turns of the window. | `dc003da3`: the keypress is a `kind=input phase=submit` row stamped with the host's clock (`rust/wa-capabilities/src/host.rs`, `TypedLine::at`), `stalls` pairs it with the run and sorts the worst list by gap |

## Item 1 - the pty test (`d7efc26e`)

`scripts/test-chat-start-pty.mjs` drives the real binary in a private tmux pty against one local fixture
that is both the rendezvous and the provider:

- `GET /nodes` answers a roster of ONE peer, marked offline (the brief's own measurement: node `work`,
  20.6 s of silence after Enter) whose endpoint is a black hole - a socket that accepts and never answers,
  so a probe of it costs its whole 20 s deadline;
- `GET /usage` is the limits stub and HOLDS 5 s;
- the completions request is recorded with the moment it arrived.

It asserts, on the screen read back and on the fixture's own arrival times: the run's numbers row appears
within 1 s of the Enter, the completions request starts within 1 s, the turn finishes and draws its
answer, and the prefetch's operation row on disk carries view specs with no problems.

Measured, same test, one binary, `WASM_AGENT_LUA_ROOT` naming each tree:

| tree | result |
| --- | --- |
| this branch | **16 ok, 0 failed** - run row 217-279 ms after Enter, roster read at 734 ms, provider request < 1 s |
| `a9d4617d` (base) | **8 failed** - no roster read at the idle prompt, the 5 s limits stub asked in the background, no prefetch child, and the three `wa stalls` checks (no submit row) |
| `d7597689` (the commit the brief names) | **9 failed** - and among them the brief's own two: the run row and the provider request never appear within 8 s |

Wired into `scripts/fast.sh` beside the other pty rows (`d7efc26e`).

## Item 2 - the idle reads leave the interpreter (`a651ea2e`, `fd37ef24`)

`lua/core/idle_reads.lua` starts `wa idle-reads --session <id>` as a supervised operation (the mechanism
`lua/core/nodes.lua` already uses for probe children) and, on a later idle tick, reads back a child that
has settled and applies its answer: `local_views.publish_spec` hands each already-built stack to the
client, and the stack is converted ONCE, in the child, by `balloon.spec` (a second conversion would apply
the page-link arithmetic twice).

A tick is a start or a `status` read of an operation that is already over; it never waits. Measured: the
roster is read at the idle prompt while the prompt stays live, the peer is never probed on this path, and
the parent logged no prefetch failure (the pty checks).

**The provider limits cannot ride in the child, and the report must say so.** A child of this node is a
tool child, and the kernel withholds every provider credential from those by policy
(`rust/wa-operation/src/lib.rs`, `DENY_ENV`: `WASM_AGENT_LLM_API_KEY` and every `*_API_KEY` / `*_TOKEN` by
shape - session isolation finding 5). Measured: a child that asked its own provider answered
`limits unavailable: provider not configured`. So the limits are read where they are ASKED for - `/status`
between runs, the reader's own request and the reader's own wait - and the snapshot a run draws uses the
last such read and says how old it is (`lua/core/status.lua`, `limits_of`). That is a behaviour change
against `a9d4617d`, where the idle prompt refreshed them every five minutes: the mid-run `/status` panel
now shows provider limits only after a `/status` (or `wa status`) between runs.

## Item 3 - `wa stalls` (`dc003da3`)

- The stamp is the host's: `TypedLine` carries the epoch second at which the line was taken from the
  reader, `input_take` answers it beside `lines`/`now`, `cli_input:poll` hands it back with the line, and
  `chat.lua` records it for the lines that become turns (`telemetry.event` gained the optional `at`).
- `stalls` pairs a run with the latest submit in its own session at or before its start, measures from
  it, reports how much of the gap was spent before the run, and counts the turns with no keypress (a
  wake, a sentinel: measured from `run/start` and said so, never guessed).
- The worst five are the five largest gaps (`d7597689`-era code listed the newest five).

Tests: `scripts/test-stalls.lua` (new, a `scripts/test-*.lua` row: 16 checks, **12 failed on
`a9d4617d`**), `scripts/test-cli-input.lua` (extended: the stamp is the moment the host queued the line,
not the moment this side asked - **fails on `a9d4617d`**), the rust row
`host::terminal_tests::a_line_carries_the_moment_the_host_saw_it`, and the pty test's `wa stalls --json`
read-back of the ledger the chat just wrote, which is the cross-process half (`fd37ef24`).

## Premises of the brief that were stale (rule 9)

- "A pty test that fails on d7597689": still true, but the 20 s probe belongs to `d7597689`, not to the
  base. On `a9d4617d` the same probe is gated by the idle prompt's own publish (`local_views`, 60 s), so
  a first Enter after an idle tick does not meet it - the leftover defect on the base is the idle read
  itself (5 s), which is what item 2 is about. The test fails on both, for two different reasons.
- "the status row is drawn in under 1 s": the row `run_started` draws on a live screen is the run's own
  numbers row (step clock, delta, tokens, run clock); between runs that row is empty and the footer
  carries the summary. The test matches the numbers row (`\u0394\u2191`) and asserts it is absent before
  the Enter.
- "a provider-limits stub that takes 5 s": it is still in the fixture, but nothing on the reader's path
  asks for it any more (see item 2). It stays so that any code that puts it back there shows up as a late
  row instead of hiding.
- A run's roster peer must be marked OFFLINE in the fixture: an online peer is also asked by the turn's
  own federation catalog, which would make the test double-faulted. Offline is the brief's premise (the
  probe waits on every peer in the roster, online or not).

## What was not done

- The full fast path was queued and killed twice by node installs (`1ffffae3`, `eb084ca8`); it is not
  re-run by this report. What WAS run on this branch: the pty row (16/16), `scripts/test-stalls.lua`
  (16/16), the rust row, and a targeted `WA_FAST_ROWS` run of the rows this change touches
  (chat-printer, cli-balloon, cli-input, local-views, mcp, mcp-command, stalls, status,
  telemetry-incremental, whatsapp-owner, view-lines, efficiency-report) - see the session's last
  operation for its verdict.
- The binary used for those runs was built with `WA_CODEMODE_ALLOW_EMPTY=1` (the code-mode assets were
  not prepared on this node), so a code-mode row would report its named skip rather than a pass.
- `federation.catalog()` still blocks inside a turn when its cache is old AND a peer in the roster is
  ONLINE and does not answer; that is a second, older defect on the same theme and it is NOT fixed here.
  The pty fixture keeps its peer offline for exactly that reason (see above).

## Texts to approve (rule 10)

1. `wa idle-reads --session <id>` - `usage: wa idle-reads --session <id>`
2. `wa idle-reads --session <id>` - `  the fresh views a chat prompt makes, in a child process: one JSON
   line on stdout`
3. `wa stalls` report head - `Enter -> first model call, last %gh: %d turn(s) - %d from the keypress, %d
   from run start` (and `, window truncated` appended when the window could not be covered)
4. `wa stalls` worst list header - `  the five slowest (and how much of each was spent BEFORE the run
   began, with the phase that run named):`
5. `wa stalls` worst row - `    %s  %8s  %s (%.2f s of it before the run)`
6. `wa --help`, the stalls line - `    stalls [--since <hours>] [--json]  Enter -> first model call:
   median, p90, the slow ones and what they waited for`
7. the node log line, once per reason - `idle reads: <reason>`

## Where the new tests run

- `scripts/test-chat-start-pty.mjs` - `scripts/fast.sh`, row `chat-start-pty` (`d7efc26e`)
- `scripts/test-stalls.lua` - a `scripts/test-*.lua` row of `scripts/fast.sh` (`dc003da3`)
- `scripts/test-cli-input.lua` - existing row, extended (`dc003da3`)
