# pinned-prompt-and-notice-row - the last request on the top row, and a notice row above it

Branch `change/pinned-prompt-and-notice-row`, base `b79da519`, worktree
`/home/victor/Work/missions/pinned-prompt-and-notice-row/wt`. Victor, 23/11 11:20Z, with a Claude Code
screenshot: *"claude code shows sticked to the top the last user input turn. we want that. and we want
on top of that sticked user input a line reserved to TUI messages that are currently being printed on
top of the session status bar like 'Copied <n> characters' ... so we never lose vision of the session
status bar, and it appears in the very top like a balloon, where it belongs."* Plus Fable's item 7:
the *Jump to bottom* pill, with the key read from the keymap.

**State: green on the rows below, not landed.** Nothing is on main, nothing is on a peer, no release,
no `~/.local/bin` install (FACTORY rule 12). The orchestrator lands; Fable reviews the captures first.

## Commits (one per finished item, as the brief asks)

| commit | item |
| --- | --- |
| `55ecc783` | keymap: the notice row and the pill are pointer gestures, and a screen names a key from the table |
| `ac0382ef` | transcript: the last request pinned at the top, a notice row above it, and the jump-to-bottom pill |
| `0f663d2f` | host: every transient message lands on the notice row (one writer), and a request is its own block |
| `d73cf71d` | test: a pty test for the jump-to-bottom pill, its key and its click |
| `a0a5908c` | transcript: the 5,000-row frame cost, measured (env-gated) |

`git diff --stat b79da519..HEAD`: `lua/core/cli_view.lua`, `rust/wa-capabilities/src/host.rs`,
`rust/wa-term/src/{keymap,terminal_editor,transcript}.rs`, `scripts/fast.sh`, and the two new pty
rows. No Lua prompt, no tool schema, no stored message.

## 1. The inventory: every transient TUI message, and where it was drawn

Re-measured on this base (`git grep`), because the brief's line numbers were from `origin/main` and
had moved: `editor.notice` is at `host.rs:4237, 4254, 4336, 4353, 4802, 4821, 4832, 5939` (the brief
said 4165/4182/4264/4281/4730), and `editor_status`' `editor.notice.clear()` at `host.rs:6032`.

| message | where it was drawn BEFORE | covered/pushed the status row? |
| --- | --- | --- |
| `Copied N characters` (a transcript selection released, `host.rs` `Mouse::Release`) | footer's left half, last row | **yes** - it *replaced* the footer's text |
| `Copied N characters` (Ctrl+C with a selection, `copy_selection`) | footer's left half | **yes** |
| `Copied N characters` (Ctrl+C on a *draft* selection, `Action::Copy`) | footer's left half | **yes** |
| `Copied N characters` (a fenced block's copy icon, `Gesture::BlockCopy`) | footer's left half | **yes** |
| `Copied link (N characters)` (a URL under a press, `Gesture::LinkCopy`) | footer's left half | **yes** |
| `[Image #n] attached (KB, WxH)` and its stray-selection warning (`attachment_notice`, paste + dropped path) | footer's left half | **yes** |
| the clipboard's refusal (`read_clipboard` -> `Err(reason)`, e.g. "no WAYLAND_DISPLAY or DISPLAY in this process ...") | footer's left half | **yes** |
| `Interrupting... (draft kept)`, `Draft kept - ctrl+u clears it - ctrl+z undoes`, `Interrupting... (ctrl+c again to quit)`, `ctrl+c again to quit` (`terminal_editor.rs:621,624,632`) | footer's left half | **yes** |
| the run's own line (`▸ 1-4s \u0394\u21910 \u21930 ...`, the ticker) | its own row above the input box | no - but it is the row Victor watches, above the bar |
| the session status bar itself (footer: last run's numbers / hints, and the model on the right) | last row | it *was* the victim |
| queued steer lines (`Steering queued`, `editor.queued`) | their own rows above the status line | no |
| the standing update notice (`session_notice`, `build_status`) | its own row between the box and the footer | no |
| the rebuild loader (`build`) | replaces the standing notice on that row | no |
| the self-wake fact (`wakes`) | its own row above the footer | no |
| the slash menu | rows above the input box | no |
| a panel / balloon (`host.panel`) | the bottom of the screen, by design | **yes, while it is open** (a page owns the screen) |
| the busy spinner + clock in the ticker | the status line | no |
| a resize's repaint (`REPAINT_CLEAR`) | the whole screen, once, debounced 150 ms | no |
| the opening animation | the alternate screen, before the chat | no |

The eight `editor.notice` sites and the four editor-composed notes all went through one field that
`Editor::render` painted **in the footer's place**, i.e. on the session status bar. That is exactly
the loss Victor described. What Victor's screenshots call "the session status bar" is the last row
(footer: the run's numbers or the hints, plus the model name on the right); the run's own line sits
one row above the input box and was never the message's row.

## 2-3-4. What the branch does

* **One writer.** `host::say(state, text, sticky)` -> `Transcript::notice(text, now, sticky)
  (`host.rs`, `transcript.rs`). Every site above now calls it; `editor.notice` is composed by the
  editor and handed over by `host::flush_editor_notice` before the frame, and `Editor::render` no
  longer paints that field at all - so there is no second place a message can be drawn from
  (`terminal_editor.rs`, commit `0f663d2f`). `editor_status` no longer clears a message when the
  run's row comes or goes: the row is not its any more.
* **The notice row** is the first row of the transcript region, right-aligned in the warm accent, and
  it is a row *of the region*: the chat is one row shorter, not overdrawn. It goes after 2000 ms
  (`NOTICE_MS`, expired by the reader thread's 150 ms idle loop via `host::expire_notice`) and an
  ERROR stays until the next key (any key or mouse report clears it, `console_reader`).
* **The pinned request** is the row under it (or the top row when there is no message): the prompt
  mark and the request's first line, clipped with an ellipsis (cell-aware, so wide characters never
  overflow), on the grey band the chat draws the reader's own turn on (`PIN_BAND`,
  `\x1b[38;2;255;255;255m\x1b[48;2;68;68;68m`, the same band `lua/core/cli_view.lua` paints).
  **One row, not two**: one row is what Claude Code keeps, and a second row would cost the chat a
  row for the same text; the brief allows two "when the window is tall", and one row that clips with
  an ellipsis says as much in the space a reader is willing to give it.
* **Which turn.** The last request whose rows are entirely above the viewport - so scrolling up into
  an older turn pins that turn's request, and a request that is on screen pins nothing.
* **A click on it** scrolls to the request: `Gesture::PinJump` -> `Transcript::jump_to_pinned`.
* **A request is its own block.** `lua/core/cli_view.lua`'s `write(text, mark)` passes `"request"`
  for the reader's turn, `host.transcript_write(text, mark)` -> `Transcript::write_marked`, which
  closes the block behind it. Without that the streamed answer appended to the request's block and
  the two could never be separated (measured: the pin never appeared during a run).
* **The pill** (item 7): `Transcript::pill_text` is drawn on the region's last row while the view is
  not following the output. Its key comes from `keymap::label(Act::Nav(NavAct::Bottom))`, i.e. from
  `BINDINGS` - never a literal - so a rebinding changes the label. It says how much is below
  (`↓ N more lines`), keeps the scrollbar's cell, and a press inside its own cells
  (`Gesture::JumpBottom`) goes back to the bottom and follows again; the key does the same. That row
  used to hold `↓ N more lines (PgDn)`; the pill replaces that marker and carries the key instead of
the hard-coded word.

## 5-6. Nothing the model reads changed

`lua/core/cli_view.lua`'s `accepted` passes one extra *argument* to a capability that already
received the same text, and `Transcript::write_marked` stores exactly the bytes `write` stored. No
prompt, no tool description, no stored message, no schema. `git diff b79da519..HEAD -- lua/core/chat.lua
lua/core/agent.lua docs/` is empty.

## Tests (all run singly here; wired where the suite can see them)

| test | proves | run |
| --- | --- | --- |
| `wa-term` unit tests (`cargo test -p wa-term --lib`) | 218 pass, including 9 new ones below | net |
| `the_request_above_the_viewport_is_pinned_on_the_top_row` | the pin is the top row, one row, with its mark | `transcript::tests` |
| `the_pinned_row_takes_its_row_from_the_region_and_not_from_the_chat` | exact proof the chat's rows are the same rows, one row lower | `transcript::tests` |
| `scrolling_up_pins_the_turn_in_view` | the pin follows the turn in view | `transcript::tests` |
| `a_session_with_no_request_yet_has_no_pinned_row` | no request, no band, the chat keeps every row | `transcript::tests` |
| `a_long_wide_request_is_one_row_clipped_with_an_ellipsis` | CJK, clipping, one row | `transcript::tests` |
| `the_notice_sits_above_the_pinned_request_and_goes_after_its_time` | order of the two rows, the 2 s life | `transcript::tests` |
| `an_error_stays_until_the_next_key` | the sticky error | `transcript::tests` |
| `the_pill_names_the_key_the_table_binds` | the label is the table's, and `pill_text("Alt+End", ...)` proves no literal | `transcript::tests` |
| `a_press_on_the_pill_or_the_key_goes_back_to_the_bottom` | the pill's own cells, the key, following again | `transcript::tests` |
| `a_press_on_the_pinned_request_scrolls_to_it` | the click lands on that turn's request | `transcript::tests` |
| `the_answer_does_not_join_the_request_block` | the block split that makes the pin possible | `transcript::tests` |
| `a_key_a_screen_names_is_the_tables_own_label` | `keymap::label` is `BINDINGS`' own key | `keymap::tests` |
| `a_notice_never_takes_the_session_status_bar` | the footer keeps its text while a message is composed | `terminal_editor::tests` |
| `frame_cost_of_a_5000_row_chat` | a MEASUREMENT, not an assertion | `WA_FRAME_MS=1 cargo test -p wa-term --lib frame_cost -- --nocapture` |
| `scripts/test-pinned-request-pty.mjs` | 26 checks: the pin during a run, the notice above it, the status bar in every frame, 2 s, the sticky error, resize, wide characters, `--continue`, and no pin before the first request | `WA_BIN=<bin> node scripts/test-pinned-request-pty.mjs` - wired in `scripts/fast.sh` as `pinned-request-pty` |
| `scripts/test-jump-to-bottom-pty.mjs` | 14 checks: the pill with the mapped key, the count growing, the key, the click | `WA_BIN=<bin> node scripts/test-jump-to-bottom-pty.mjs` - wired in `scripts/fast.sh` as `jump-to-bottom-pty` |

Both pty rows start tmux through `scripts/lib/tmux-session.mjs`, create their own scratch
`HOME`/`WASM_AGENT_HOME` outside the real `~/.wasm-agent` and refuse to run inside it, and FAIL (never
skip to a pass) when the fixture served nothing.

**Discrimination (rule 16).** Measured, not assumed: `scripts/test-pinned-request-pty.mjs` on the
base binary reports 12 ok / 11 failed (`the pinned request is the row UNDER the message`, `the
session status bar is untouched by the message`, `the status bar keeps its text in every frame`, `the
pinned request is the top row again`), because on the base the message is drawn in the footer's place
and there is no pinned row at all. The `wa-term` unit tests are about symbols (`Transcript::notice`,
`pin_line`, `pill_text`, `write_marked`) that do not exist on the base, so they cannot compile there:
the reverted-non-test form of this branch fails to build its own tests, which is the strongest form
of "fails on the base" and is stated plainly rather than dressed up as a red assertion.

## The rows I ran, and the one run that was cut

Each Lua row singly against this tree's binary (`WA_SCRIPT=<row>`, its own scratch `HOME`), because a
narrowed `scripts/fast.sh` was killed twice by the node re-installing itself mid-run (nine installs
landed during this session: `dc2a60ce`, `a029d0d5`, `82d09add`, `1cc642f8`, `8010d293` among them).
The `fast.sh` log stopped after `fast: components ... pinned` with no row line and no EXIT, so it
proves nothing and is not counted as green.

| row | result |
| --- | --- |
| `scripts/test-host-return-docs.lua` | ok (10 checks; 40 JSON-text capabilities documented) |
| `scripts/test-cli-view.lua` | ok (566 checks) |
| `scripts/test-cli-notice.lua` | ok (11 checks) |
| `scripts/test-cli-resize.lua` | ok (81 checks) |
| `scripts/test-cli-welcome.lua` | ok (15 checks) |
| `scripts/test-cli-interrupt.lua` | ok (27 checks) |
| `scripts/test-cli-steering.lua` | ok |
| `scripts/test-transcript-view.lua` | ok (11 checks) |
| `scripts/test-keybindings.lua` | ok (53 checks, 0 failed) |
| `scripts/test-prompt-tool-names.lua` | ok (288 checks, 0 skipped) |
| `scripts/test-prompt-golden.lua` | ok (20 checks) |
| `scripts/test-cli-flow.lua` | **1 failed of 14**: `exactly one blank line under it` - **pre-existing**, `scripts/row-at-sha.sh b79da519 scripts/test-cli-flow.lua` answers `class=pre_existing` (base exit 1, change exit 1) |
| `scripts/test-tmp-cleanliness.mjs` | PASS (9 checks) - including "every pty row that starts a tmux server does it through the helper (16 files scanned)" |
| `cargo test -p wa-term --lib` | 218 passed, 0 failed |
| `scripts/test-pinned-request-pty.mjs` | 26 ok, 0 failed |
| `scripts/test-jump-to-bottom-pty.mjs` | 14 ok, 0 failed |

**Not run here**: the full suite (`scripts/test.sh`, `fast.sh`, `preflight`), per the G wave's rule - a
landing runs no gate and main-health runs the full check on main.

## 6. The frame cost of a 5,000-row chat (measured, not argued)

`WA_FRAME_MS=1 cargo test --release -p wa-term --lib frame_cost -- --nocapture`, 5,000 rows at
120x40, one process per line - the base in its own worktree (`git worktree add /tmp/pm-base
b79da519`, removed afterwards), the branch in this one. Milliseconds per `view()`:

| | following the bottom | frozen a page up |
| --- | --- | --- |
| base `b79da519` | 4.24, 3.38, 3.99 (mean 3.87) | 5.58, 3.75, 3.87 (mean 4.40) |
| this branch | 3.25, 4.23, 5.01 (mean 4.16) | 3.63, 3.92, 4.00 (mean 3.85) |

**Read this as "no regression", not as a win:** the run-to-run spread on a shared 16-core node is
about a millisecond, which is larger than the difference. What it does establish is that the two
reserved rows cost nothing a reader can feel: the pin reuses the per-block row counts the scrollbar
already keeps (`total_rows`, cached), the notice is a `String`, and the pill is one row's text.

## Captures for Fable (the three states)

In `docs/missions/reports/pinned-prompt-and-notice-row/`, produced by the real binary in a real pty
(100x40) against the same slow fixture the pty row uses:

* `state-a-pinned-only.txt` - a run streaming, the request on the top row, its answer scrolled past;
* `state-b-pinned-and-notice.txt` - the same frame plus `Copied 11 characters` on the notice row,
  the pinned request one row under it, the status bar untouched;
* `state-c-neither.txt` - a session with no request yet: no pinned row, the welcome screen;
* `state-d-after-two-seconds.txt` - the same as B, 2.5 s later: the message is gone and the pin is
  back on the top row.

## Assertions I changed (named, as rule 6 requires)

No assertion was deleted or loosened. Four had to follow a behaviour the brief changes, and each one
is at least as strong on the new behaviour:

1. `terminal_editor::tests::ctrl_c_never_wipes_the_draft`: `e.render().contains("Draft kept")` ->
   `e.notice.contains("Draft kept")` **plus** `!e.render().contains("Draft kept")` (a new, opposite
   assertion: the note is never on that row).
2. The same test: `e.render().contains("Interrupting\u{2026} (draft kept)")` ->
   `e.notice.contains(...)` **plus** `!e.render().contains("Interrupting")`; and the closing
   `!e.render().contains("Interrupting")` ("lasts one keystroke") -> `!e.notice.contains(...)`, the
   same claim on the field that now carries it.
3. `transcript::tests::page_up_and_down_scroll_the_view` and
   `a_frozen_view_does_not_move_while_output_arrives` assert `contains("more lines")` on the last
   row: still asserted, now on the pill's text (the pill carries that count).
4. `transcript::tests::a_long_chat_draws_a_scrollbar_and_its_position_follows_the_reader` counts ten
   bar cells; still ten - the pill re-appends the bar's cell of the row it covers.

## Texts to approve

New operator-facing strings, verbatim:

1. `Jump to bottom ({key}) \u{2193}` - the pill when there is nothing below it (a frozen view at the bottom).
2. `\u{2193} {n} more lines \u{b7} Jump to bottom ({key}) \u{2193}` - the pill while output waits below (80 columns and wider).
3. `\u{2193} {n} more lines \u{b7} {key} \u{2193}` - the same on a narrow window, where the sentence does not fit and the key must survive.
4. `{key} \u{2193}` and `Jump to bottom \u{2193}` - 2 and 3 when the keymap has no key for `NavAct::Bottom` at all (an unbound Bottom still offers the way back).
5. `/keybindings` rows (reader-facing, they are the table's words and they are new):
   * `press the request pinned at the top of the transcript: scroll to that turn's request`
   * `press the notice row: the message goes now, instead of when its time is up`
   * `press the jump-to-bottom pill: back to the newest output, and follow it again`
6. Every message from the inventory keeps its words EXACTLY (`Copied N characters`, `Copied link (N characters)`, `[Image #n] attached (...)`, the stray-selection warning, the clipboard refusal sentences, `Interrupting\u{2026} (draft kept)`, `Draft kept \u{b7} ctrl+u clears it \u{b7} ctrl+z undoes`, `Interrupting\u{2026} (ctrl+c again to quit)`, `ctrl+c again to quit`): they changed ROW, not wording.
7. The pin shows the request's own text, including the `\u{276f} ` mark it was sent with, clipped with `\u{2026}`.

## Proposed FACTORY.md text (NOT written)

> **A transient message has a row of its own, and it is not the status bar.** In the native
  transcript layout the window's first row belongs to transient TUI messages and the second to the
  last request that scrolled off the top; the session status bar (the footer) and the input box are
  never borrowed for a message. One function writes it (`host::say` -> `Transcript::notice`): a
  message printed from anywhere else is a bug, not a shortcut. It goes after two seconds; an error
  stays until the next key.

## Proposed HANDOVER.md text (NOT written)

> **The chat's top rows (change/pinned-prompt-and-notice-row, `ac0382ef`).** `Transcript::view_at`
  reserves up to two rows of the region at the top: the notice row (`Transcript::notice`, one writer,
  2 s or until the next key for an error) and the pinned request (the last block marked `request` -
  `write_marked`, passed as `host.transcript_write(text, "request")` from `cli_view.lua`'s `accepted`
  - whose rows are entirely above the viewport). A request gets a block of its own; without that the
  streamed answer joins it and the pin can never fire. While the view is not following the output,
  the region's last row carries the jump-to-bottom pill whose key is `keymap::label(Act::Nav(
  NavAct::Bottom))` - read from the table, never written down. `Editor::notice` is composed by the
  editor and DRAWN on the notice row (`host::flush_editor_notice`): the footer is the status bar and
  nothing else, which is what Victor asked for on 23/11.

## What I did not verify, and what is still open

* **A real desktop terminal, by eye.** Everything here is the real binary in a real pty read by
  tmux; the band's *colour* is asserted in a unit test (`PIN_BAND`) and not on the capture, because
  tmux may re-quantise RGB on capture. Fable's review of the four captures is the check that was
  asked for, and it is a text capture.
* **`wa chat` on a 3-row window.** The code keeps one row of region for the chat
  (`height.saturating_sub(1)`), but no test drives a window that short.
* **The panel/balloon** still owns the screen while it is open (by design, unchanged): a message
  that arrives then is drawn under it, and the pty row does not exercise that overlap.
* **A rebinding of Bottom** is proven at the level of `keymap::label` + `pill_text(key, ...)`, not by
  driving a rebound table through a pty: `BINDINGS` is a `const`, so there is nothing to rebind at
  run time yet.
* **The `WA_CODEMODE_ALLOW_EMPTY=1` binary.** The pty rows here ran a test build without the
  code-mode assets (the gate's own switch), which is why a capture shows `! code mode unavailable`;
  that line is not this branch's and does not touch these rows.
