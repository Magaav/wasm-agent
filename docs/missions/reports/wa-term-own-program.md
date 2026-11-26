# wa-term-own-program - step 3: the terminal UI is its own program (slice 1, the transcript)

VERDICT: **done and verified for slice 1**. The transcript - its state, its rows, its notice row, its
pinned request and its scrollbar - now lives behind a versioned wire in the terminal program
(`wa-term`, a binary of `rust/wa-term`) and the node speaks to it when `WA_TERM_REMOTE=1`. The
switch is OFF by default and the default path is the same crate call it was. Two new rows prove the
screen did not change: one drives the SAME event log through both paths in two real processes and
compares every answer and every frame byte for byte; the other puts the real binary in a real pty,
draws the same chat twice and compares the screens row by row, with a spawn mark that fails the row
if the wire was not actually used. Every existing row I ran is unchanged and green.

Commits on `change/wa-term-own-program` (base `origin/main` 522e12ae):

| commit | what |
| --- | --- |
| ca741ecd | the wire (`rust/wa-term-proto`), the program (`wa-term`, `session.rs`), the node's handle (`rust/wa-capabilities/src/screen.rs`), the host edits, and the two-process equivalence test |
| (amended into the above) | the plan is in `ready-wa-term-own-program.md` in the mission directory, written before the code |
| second commit of the branch | the pty row, its wiring in `scripts/fast.sh`, and three unit tests in the program's session |

## 1. The measurement the brief asked for (re-measured here, not from the brief)

| fact | number | how |
| --- | --- | --- |
| `rust/wa-term` source | 11,213 lines in 17 files (tests: 1,396) | `find rust/wa-term/src -name '*.rs' \| xargs wc -l` |
| commits in the last 30 days touching `rust/wa-term` | 104 | `git log --since=30.days --format=%H -- rust/wa-term \| wc -l` |
| of those, touching nothing but `rust/wa-term` | 16 | the same list, minus every commit with a file outside it |
| commits in the last 30 days, all of main | 2,947 | `git log --since=30.days --format=%H \| wc -l` |
| churn per file, 30 days | transcript.rs 52, terminal_editor.rs 34, keymap.rs 9, lib.rs 8, opening.rs 6 | `git log --since=30.days --format=%H -- <file> \| wc -l` |
| `wa_term::` call sites in the node's console, at base | 131 lines, of them 86 on the transcript (46 distinct methods and fields) | `grep -c 'wa_term::' rust/wa-capabilities/src/host.rs` in a `origin/main` worktree, and `grep -o 'transcript\\.[a-z_]*' ... \| sort -u \| wc -l` (129 / 87 / 49 on this branch: the field's type and the scrollbar parse moved behind the handle, and five calls were added by `Screen`) |
| crates depending on `wa-term` | 1 (`rust/wa-capabilities`) | `grep -rn 'wa-term' rust/*/Cargo.toml` |

The 88 commits that touched more than `rust/wa-term` mostly also touched `lua/core/cli_view.lua`
and/or `rust/wa-capabilities/src/host.rs` (0f663d2f, 1c59dd8e, 8fccc833 are three): a display-only
change is a three-tree change today, and the host half of it is the rebuild this mission exists to
remove.

### What the transcript needed from the host (file:line, as it was before this branch)

- **a field of the console's global state**: `host.rs:4129`, inside `struct ConsoleInput`
  (`host.rs:4118-4175`), reachable only through `console_input()` (`host.rs:4425-4436`);
- **the screen size**: `console_size()` (`host.rs:3939` unix ioctl, `3991`, `4017`), with the
  region from `output_rows` (`host.rs:4471`) and `Editor::width`;
- **the tty**: raw mode `wa_term::terminal_editor::try_raw()` (`host.rs:5064-5066`), bytes out
  through `terminal_editor::write` (`wa-term/src/terminal_editor.rs:27`, `io::stdout()` at `:42`)
  at 131 call sites, keys in from the reader thread `console_reader` (`host.rs:4727`, one
  `libc::read(0,...)` at `4703`), decoded by `wa_term::selection::take` (`4774`) and
  `wa_term::keymap` (`4789-4943`);
- **the chat loop drawing through it**: `layout_frame` (`host.rs:4487-4514`) -
  `transcript.render` at `4500`, the selection overlay at `4501`, `bar_frame` at `4505`, gated
  by `dirty` (`4499`, cleared at `4507`) - called from 36 sites;
- **the Lua view talking through the host**: `host.transcript_write` (`5426`),
  `transcript_block` (`5489`), `transcript_fold` (`5503`), `transcript_copy` (`5554`),
  `transcript_expand` (`5577`), `transcript_card` (`5596`), from `lua/core/cli_view.lua:1408`,
  `:1425`, `:1460`;
- **state read back out**: `dirty` (13 sites), `scrollbar` (`4434`), `blocks.last().code`
  (`4601`), `bar()`/`bar_active()` (`4303`, tests `6595-6631`), `text_width` (`4339`),
  `following` (`4183`, `4333`).

## 2. The boundary, as built

- **The program**: `wa-term`, a native binary of `rust/wa-term`
  (`cargo build -p wa-term --bin wa-term`). Native and not a WASI component on purpose: it is the
  thing that holds a terminal, and a WASI component has no tty. It is found at `WA_TERM_BIN`, then
  beside the `wa` executable (an install ships the pair), then on `PATH`.
- **What goes over it**: one message = one call the node already made on the transcript, with its
  arguments and its return (`{"v":1,"op":"call","method":"render","args":[100,30]}` ->
  `{"v":1,"ok":{"frame":"<base64>"},"dirty":false}`). ndjson over two pipes; byte payloads base64.
  The method table IS `wa-term`'s own API (`rust/wa-term/src/session.rs`), so a display-only change
  adds no field to the protocol - which is the property the whole move rests on.
- **Nothing private crosses**: `counts`, `bar_last`, `pin_shown`, `reserved` and the rest stay
  with the painter. The clock stays there too (`notice`, `expire_notice`, a frame's notice row read
  `Instant::now()` in the program): one owner for the two-second rule.
- **How a session attaches (slice 1)**: the child's lifetime is the session's. The node creates the
  console state once (`console_input()`, `host.rs:4425`) and `Screen::for_console()` decides the
  path there; the first call spawns and handshakes, and `Drop` kills the child on every path this
  process can take. The socket-per-session attach (so a program can be restarted without losing the
  scrollback) is named in the plan and NOT built: a socket without a detach story would be untested
  surface.

### Refused by name (never a silent fallback)

| name | when | test |
| --- | --- | --- |
| `term_switch_invalid` | `WA_TERM_REMOTE` is neither `1` nor `0` | `tests/term_remote.rs`, and the pty row on screen |
| `term_program_missing` | no program at `WA_TERM_BIN`, beside the executable, or on `PATH` (all named in the message) | `tests/term_remote.rs`, and the pty row on screen |
| `term_protocol_mismatch` | the program speaks another protocol (both numbers in the message) | `tests/term_remote.rs` |
| `term_call_failed` | the program died, or answered a line that is not a reply; the failure STICKS and no frame is drawn from it | `tests/term_remote.rs` |
| `term_unknown_method` | the node called a method this program does not have | `wa-term/src/session.rs` tests |
| `term_bad_message` | a message that is not this protocol (bad args, unknown scrollbar setting, unparseable line) | proto + session tests |

`host.input_start` (`host.rs:5064`) asks for the handshake BEFORE it takes the screen: a refusal
prints one line and the chat runs without the editor, rather than the node drawing into a program
that is not there.

## 3. What stays in the node, and the order after this slice

Stays (unchanged by this branch): the pty and raw mode, the reader thread and the key decision, the
selection and the clipboard, the editor and the panel, the frame gate (`dirty`) and the write to the
tty, the Lua surface (`host.transcript_*` keeps its name and forwards), and the satellite rows
(`tool_progress`, `build_status`, `opening`).

Next, each its own switch and its own rows: editor + keymap -> selection/copy -> opening,
tool_progress, build_status -> then the node drops `wa-term` and the in-process path is deleted.
That last commit is the one that stops a display change from rebuilding the host, and it is the one
that changes what the host links - after the v0.1.2 tag, decided by the orchestrator.

## 4. How a TUI-only change ships without a host build (measured on this node, avell)

| what | before this branch | with the wire (`WA_TERM_REMOTE=1`) |
| --- | --- | --- |
| a display-only change (touch `rust/wa-term/src/transcript.rs`), rebuild the node | 21.0 s / 22.0 s / 22.2 s (three runs, base worktree) | not rebuilt |
| the same change, rebuild the program only | - | **3.3 s**, one file of **905,320 B** |
| the same change, rebuild the node anyway (default path still in process) | - | 21.8 s / 25.6 s / 21.1 s (three runs) |

Full release build of the node (`cargo build --release -p wa-host`, `WA_CODEMODE_ALLOW_EMPTY=1`,
fresh target directory each, same machine, one after the other):

| | cold build | binary |
| --- | --- | --- |
| base `origin/main` 522e12ae (clean worktree) | 204,438 ms | 78,372,976 B |
| this branch | 173,052 ms | 78,520,024 B (**+147,048 B, +0.19%**) |

The cold numbers say what they are: the pair moved the *other* way round in an earlier pair
(166,210 ms base vs 242,146 ms here, run in the other order), so on this machine the cold build time
is dominated by its own state and moves by tens of seconds between runs; what the branch adds to it
is one small crate and 471 lines, and the binary's +0.19% is the honest size answer. The number that
is stable and that the mission is about is the row above: **21 s of node rebuild per display change
becomes 3.3 s of program rebuild.**

## 5. Rows

| row | verdict | ms | what it proves |
| --- | --- | --- | --- |
| `rust/wa-capabilities/tests/term_remote.rs` | 5 of 5 pass | 40 | ONE event log through a fresh in-process `Transcript` and a fresh `Screen::Remote` attached to the REAL `wa-term` (two processes): the chat, a notice, a pinned request, a folded code block, 40 rows, bar hover/press/drag, a page, the bottom, a resize, a hold, a rewrite - every answer and every frame compared byte for byte; plus the four refusals |
| `scripts/test-term-remote-pty.mjs` | 11 of 11 checks | 11,109 | the real binary in a private tmux pty, the same fixture chat twice (`WA_TERM_REMOTE` off and on), transcript rows identical byte for byte, chrome identical after masking the run's own numbers; the program's spawn mark proves which path ran, and is required to be EMPTY after the in-process run; both refusals on screen |
| `cargo test -p wa-term -p wa-term-proto` | 222 + 6 pass | 350 / 0 | the crate and the wire are unchanged/covered |
| `cargo test -p wa-capabilities --lib -- host::` | 107 pass | 7,020 | the node's console tests, on the default path |
| `scripts/test-pinned-request-pty.mjs` | 26 ok, 0 failed | - | the pinned row and the notice row, existing behaviour |
| `scripts/test-tui-chrome-pty.mjs` | 18 ok, 0 failed | - | the box, the scrollbar, a resize |
| `scripts/test-reflow-blocks-pty.mjs` | 32 ok, 0 failed | - | wrapping and the bar |
| the whole `wa-capabilities` crate (`cargo test --release -p wa-capabilities`) | 407 pass, 5 fail | 8,110 | the five failures are PRE-EXISTING: `origin/main` 522e12ae in its own worktree fails exactly the same five with the same counts (407 passed; 5 failed) - `capabilities::tests::documented_inventory_matches_the_live_registry`, `operations::adoption_survives_the_relay_deadline::an_adopted_operation_survives_the_relay_deadline_and_runs_once`, `operations::await_returns_at_its_own_wait::a_cancelled_shell_returns_before_its_settle_finishes`, `operations::await_returns_at_its_own_wait::a_relayed_await_answers_at_wait_ms_and_never_holds_the_relay`, `operations::promotion_says_so::a_promoted_shell_says_in_the_same_result_that_it_moved_to_the_background` |

Both new rows are wired: `scripts/fast.sh` builds the program in its Rust section (so the
two-process test finds `wa-term` in the same target dir) and runs `term-remote-pty` beside
`chat-start-pty`. The two-process test is also found by `cargo test -p wa-capabilities` on its own.

**They fail on the base** (quality rule 16): `term_remote.rs` does not compile there
(`wa_capabilities::screen` does not exist), and `scripts/test-term-remote-pty.mjs` run against
`origin/main`'s own binary ends `FAIL - test-term-remote-pty: 0 of 1 checks` - the base ignores
`WA_TERM_REMOTE=banana` and starts the chat, so `term_switch_invalid` never appears (measured,
30.3 s).

### Through the runner (the fast path), with `WA_FAST_ROWS` narrowed to the rows this change touches

`bash scripts/fast.sh` with `WA_FAST_ROWS` naming `scripts/test-cli-view.lua` and
`scripts/test-cli-notice.lua` (the two console rows this change is on the path of): **156 checks, 154
passed, 2 failed, 0 skipped, 1,585 s**. The two failures are the two Rust rows, and neither is this
branch's:

- `rust wa-capabilities` (exit 101) - the five pre-existing tests named in section 5. The same row
  fails with exit 101 in fast runs of branches that do not contain this change (e.g. `wt69`
  2026-11-24T14:41, `wt86` 2026-11-24T23:11, read from their own `wa-fast-result.json`).
- `rust wa-term` (exit 101) - **NOT REPRODUCIBLE here**: the same command the runner runs
  (`cargo test --release -p wa-term`, scratch `HOME`, the runner's own target dir) was run ten times
  in a row on this branch and failed none: 225 + 1 + 1 + 4 + 7 + 1 tests green, ten times. It also
  fails with exit 101 in fast runs of branches that predate this one (`wt81` 2026-11-25T10:29, `wt90`
  2026-11-25T22:20), under the same heavy load (that run built `wa-host` for 225.8 s while another
  mission compiled on the same machine). The runner keeps no log for a Rust row, so the failing test
  name is not recorded - stated rather than guessed. If it recurs at the gate it should be treated as
  a flaky row of the machine, not as this branch's, and it can be named then.

The runner's build-time table also shows the row this branch wired in: **`wa-term (program)` 8.8 s,
14 units compiled** (a warm build in that run), beside `wa-term` 4.7 s and `wa-capabilities` 22.4 s.

Its module report flags one co-change pair: `crate:wa-term + crate:wa-term-proto` (2 of 2 commits
touch both, 100%). That is by design and not an accident to be merged away: the wire is a separate
leaf precisely so the node can keep speaking it after it stops linking `wa-term` (section 3), and
every commit of this slice necessarily touches both until that day.

## 6. How the tests keep their promises

- **two real processes, one machine**: the equivalence test spawns the real program binary (no stub,
  no hand-written fake in the happy path); the only fakes are the three that must MISBEHAVE (a
  program that speaks protocol 2, one that dies after the handshake, a path that does not exist) and
  each says which refusal it is there to prove.
- **scratch state, never the real home**: every fake program this file writes goes to a scratch
  directory chosen outside `~/.wasm-agent` and the helper refuses to run when it would land inside
  it; the pty row is `scripts/test-pinned-request-pty.mjs`'s isolation (a scratch HOME that refuses
  to be the real one, `env -i` with an allow-list, no relay, no rendezvous, a private tmux server, a
  fresh ledger per run) plus a local fixture provider that must serve the answer (the row FAILS when
  it served nothing).
- **no live fleet**: nothing in the two rows calls a node, a peer, `wa call`, `land` or `deploy`;
  the only network endpoint is `127.0.0.1` on an ephemeral port.
- **parity first**: the old path's real output is the golden value here and it is taken from the old
  path itself in the same run (`Screen::Local`), not from a recorded file that could have drifted.
- **no product table is created by hand**; the rows read no store beyond the ledger the product's own
  `wa chat` opens.

## 7. Texts to approve (verbatim, new and operator-facing)

Environment knobs: `WA_TERM_REMOTE` (`1` = the terminal program, `0`/unset = in process) and
`WA_TERM_BIN` (the program's path).

One line on stderr, always `wa: <code>: <message>`:

1. `wa: term_switch_invalid: WA_TERM_REMOTE=banana: it takes 1 (the terminal program) or 0 (in process)`
2. `wa: term_program_missing: no wa-term found - tried WA_TERM_BIN=/x, beside the executable (/y/wa-term), PATH (/usr/bin:/bin)`
3. `wa: term_protocol_mismatch: this program speaks protocol 2, the terminal speaks 1`
4. `wa: term_call_failed: the terminal program exited while answering 'render'`
5. `wa: term_call_failed: answering 'write': a message that is not JSON (expected value at line 1 column 1): <first 200 bytes>`
6. `wa: term_call_failed: could not start /path/wa-term: No such file or directory (os error 2)`
7. `wa: term_call_failed: could not say hello to /path/wa-term: <io error>`
8. `wa: term_call_failed: could not send 'render' to the terminal program: <io error>`
9. `wa: term_call_failed: /path/wa-term exited before it answered the handshake`
10. `wa: term_unknown_method: this program has no method 'widgets' (protocol 1)`
11. `wa: term_bad_message: <what is wrong>: <the offending message, first 200 bytes>` - the shapes
    are: `argument 0 must be a string`, `argument 0 must be a number`, `argument 0 must not be
    negative: -1`, `argument 0 must be true or false`, `argument 0 must be a string or null, not
    1`, `argument 0 must be a list of [row, marker]`, `argument 0 must be a list of [first, last]`,
    `a marker that is not [row, text]: ...`, `a marker's row is not a number: ...`, `a marker's
    text is not a string: ...`, `a range that is not [first, last]: ...`, `a range's first row is
    not a number: ...`, `a range's last row is not a number: ...`, `no scrollbar setting called
    'banana'`, `a call without a method: ...`, `args that are not a list: ...`, `not a call: ...`,
    `a reply with neither ok nor err: ...`, `hello without a protocol number: ...`, `a payload
    that is not base64 (...): ...`, `a message that is not JSON (...): ...`
12. The program's own stderr (a human's copy, never parsed by the node):
    `wa-term: <code>: <message>`, and on a handshake mismatch
    `wa-term: term_protocol_mismatch: this program speaks protocol 1, the terminal speaks 2`.

## 8. Premises of the brief that were wrong or stale

- The brief says the TUI is `rust/wa-term`; it is, but the crate is a **library the node links**
  (`wa-capabilities` is its only dependent), not a program - so "its own program" needed a binary
  target, which this branch adds.
- `rust/wa-term/src/transcript.rs`'s notice code was NOT touched (copied-notice-floats owns it):
  `git diff 522e12ae..HEAD -- rust/wa-term/src/transcript.rs` is empty. The whole file is unchanged;
  `session.rs` (new) and `bin/wa-term.rs` (new) are the program's additions to that crate.
- The brief's "how many commits touched ONLY wa-term" is 16 of 104 in the window, not the majority:
  the coupling to `lua/core/cli_view.lua` and `host.rs` is what makes the churn expensive, not the
  isolation of the crate (it is already a leaf).

## 9. What this branch does NOT do

- It does not delete the in-process path and does not unpin `wa-term` from the node: the node still
  links it, so a display change still rebuilds the host until the last slice lands (21 s, measured).
- It does not touch `capabilities.rs` at all (`git diff --stat 522e12ae..HEAD --
  rust/wa-capabilities/src/capabilities.rs` is empty): the capability registration belongs to
  `capability-registration-is-data`. `host.rs` IS changed, and only in the console's own code - the
  transcript field's type, its 13 `dirty` sites, the scrollbar setter, `last_is_code`, and the
  `input_start` refusal line - never in the registry. The files this branch touches are exactly the
  ones the move names, plus `scripts/fast.sh` (where the rows are wired) and this report.
- It changes no model request, and that is a fact about the diff, not a claim: `git diff --stat
  522e12ae..HEAD -- lua/` is EMPTY, so not one byte of the prompt, the tool manifest or the view the
  provider sees changed (the pty rows still make their two provider requests and print the answer,
  which is what their fixture checks).
- It installs nothing: `~/.local/bin` and `installed.txt` are untouched, and `components.lock` is
  unchanged (a native program is not a WASI component; the plan says how it will be pinned when the
  in-process path goes).
- It does not build the editor, the keymap, selection/copy or the satellite rows across the wire;
  those are the next slices in section 3.
