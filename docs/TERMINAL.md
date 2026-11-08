# The terminal: the inline console and the fullscreen transcript

`wa chat` draws on a terminal it owns. There are two ways it can do that, and the difference is
*where the output region is*, never how the input behaves:

- **inline** (the default today, and the fallback always available): the chat is drawn into a scroll
  region above a pinned input box (`rust/wa-term/src/transcript.rs`, `terminal_editor.rs`, driven by
  `lua/core/cli_view.lua`). The terminal's own scrollback still holds whatever was printed before the
  frame existed, and the wheel pages the chat.
- **fullscreen** (pi's console): the alternate screen belongs to the program for the length of the
  session, the transcript fills everything above the input box, and the reader scrolls it while the
  agent keeps streaming (`rust/wa-term/src/scroll/`). Below the transcript nothing moves: the same
  input box, the same status line the ticker writes, the same footer with the model on the right.

The inline console is unchanged byte for byte, and the fullscreen console cannot run unless a caller
chooses it: `scroll::Console::frame` returns an empty string in `Mode::Inline`, `enter`/`leave` return
nothing at all, and `feed` hands every byte back to the caller. A pipe, a dumb terminal or an old
binary therefore behaves exactly as it did before this existed.

## Layout

Bottom up on a screen of `H` rows (`Console::frame` pins the editor and takes the rest):

| rows | owner |
| --- | --- |
| `1 .. Editor::out_bottom()` | the transcript: chat, marker row, scrollbar column |
| `out_bottom()+1` | the status line, while a run is in flight (the host's ticker owns it) |
| `.. H-3 .. H` | the input box: top border, up to three draft rows, bottom border |
| `H` | the footer: hints or the last run's numbers on the left, the model on the right |

That is `editor.row = H - 1` and the same `out_bottom()` the inline console already draws into, so the
box, the slash menu, a panel, queued steering lines and the rebuild row all keep working untouched.

Both heights are re-derived on every frame, so a resize moves the chat's region with the box. The
frame only writes rows whose text changed (a full clear on a size change), which is what makes a
streaming answer cost the rows that grew instead of the whole screen.

## The status row does not blink

The run-status line used to disappear and come back on every tool call: `cli_view`'s `clear` erased
the status row (`\27[2K`) before *any* transcript write, and the line was drawn again a moment later.
On a screen the status line has a row of its own, so that erase was never needed - nothing else
writes there - and the pair of writes is what a reader saw as a blink.

What the view does now, and what the tests pin:

- `clear` leaves that row alone on a screen; the inline layout (where the status line shares the
  reader's row) keeps its bounded blanking exactly as it was.
- `status_draw` updates the row in place: address, the line, a pad over the columns the last frame
  drew, then `\27[K` for the tail a wider mark may have left - the same rule `ticker_frame` follows
  in `wa-capabilities`.
- The line is taken off its row once, where a run ends (`status_blank`), not before every write.
- Each frame - a transcript write plus the status, footer and session-status-content redraws that
  follow it - is wrapped in synchronized output (DEC private mode 2026: `\27[?2026h` … `\27[?2026l`).
  A terminal that implements the mode paints the frame as one update; one that does not ignores both
  sequences and behaves as it did. A frame that writes nothing emits neither.
- `rust/wa-term`'s editor leaves the status row alone for the same reason (`Editor::render`: "left
  alone: the ticker owns it"), so the host's transcript redraw does not disturb it either.
- `WASM_AGENT_CLI_SYNC=off` turns the frames off (the knob beside `WASM_AGENT_CLI_FRAME` and
  `WASM_AGENT_CLI_TICKER`) for a terminal whose mode-2026 support is worse than the tearing it
  prevents. It turns off the frames only: the erase is gone either way, so the blink does not come
  back with the knob.

`scripts/test-cli-view.lua` measures it: a scripted turn of ten tool calls on the boxed layout, one
check per frame that the line is still on its row, and **zero** `\27[2K` writes to that row. Putting
the erase back makes four of those checks fail, with one erase per tool call.

## Keys

Bound by default:

| key | action |
| --- | --- |
| PageUp / PageDown | one page: the transcript's height less one row, so a row of context stays |
| Ctrl+Home | the oldest row |
| Ctrl+End | the newest row, and follow new output again |
| Ctrl+O | collapse/expand tool output (collapsed by default: the tool's own line, two lines, `… +N lines`) |
| Ctrl+T | collapse/expand thinking (collapsed by default: the title and `… +N lines`) |

Half-page and line scrolling exist and are **unbound by default**, because the chords that suit them
(Ctrl+U, Alt+V, …) belong to the draft until an operator says otherwise:

```text
WA_TUI_KEYS=alt+v=half-page-down,ctrl+u=line-up,pageup=none
```

Actions: `page-up`, `page-down`, `half-page-up`, `half-page-down`, `line-up`, `line-down`, `top`,
`bottom`, `toggle-tools`, `toggle-thinking`, and `none` to unbind. Key names:
`pageup`, `pagedown`, `home`, `end`, `ctrl+home`, `ctrl+end`, `up`, `down`, `shift+up`, `shift+down`,
`ctrl+u`, `ctrl+d`, `ctrl+y`, `alt+v`, `ctrl+o`, `ctrl+t`, `f5`, `f6`.

Every other byte - every letter, every editor chord, a lone Esc, an unknown escape sequence - is
forwarded to the input editor exactly as read. The chat can only take a key an operator bound to it
(or one of the five above); Ctrl+C stays the editor's interrupt, Eof stays Ctrl+D, and the slash menu,
history recall, undo/redo, paste and bash mode are untouched. A mouse report is not a key: wheel
reports never reach the draft.

## Scrolling, the marker, the wheel and the scrollbar

The position is kept as **rows above the bottom** (`Chat::scrolled`), and output that arrives while the
reader is scrolled up adds its rows to it: the first visible row keeps showing the same text. What
cannot be seen is counted on the last row as `↓ N new lines` (the rows that arrived, at the current
width and folds). Ctrl+End - or a PageDown that reaches the end, or the wheel down - returns to
following, and the marker goes.

The wheel scrolls `WA_TUI_WHEEL_LINES` rows per event: `auto` (three, the inline console's own step)
or a number. The scrollbar takes the right column: `auto` (only when the transcript overflows),
`always`, or `hidden`; the text re-wraps one column narrower while it is shown.

## Settings, in the node's config

The node's config file is `<config>/env`, `KEY=VALUE` per line, loaded into the process environment at
startup (`load_env_file` in `rust/wa-host/src/main.rs`), which is how the console's existing knobs
already work (`WASM_AGENT_CLI_EDITOR`, `WASM_AGENT_CLI_FRAME`). The fullscreen transcript reads:

```text
WA_TUI_FULLSCREEN=on            # on | off (default on)
WA_TUI=inline                   # inline | fullscreen: overrules the setting above
WA_TUI_SCROLLBAR=auto           # auto | always | hidden
WA_TUI_WHEEL_LINES=auto         # auto | a positive number of rows
WA_TUI_KEYS=...                 # key=action, key=action, key=none
```

The fallback is chosen in this order: `--inline` on the command line, then `WA_TUI=inline`, then "no
terminal" (a pipe or a redirected stream cannot be fullscreened), then `WA_TUI_FULLSCREEN`. A value
that does not parse is left at its default and named in `Settings::warnings` - a knob that was ignored
is not a knob that was applied.

## Giving the terminal back

`scroll::Guard::arm(mode)` restores the terminal on `Drop` - a normal exit, an early `return`, or a
panic unwinding - and is idempotent, so an explicit `leave()` and the drop cannot fight.
`scroll::install_panic_restore(mode)` additionally gives the screen back *before* a panic's message is
printed, because a panic on the alternate screen leaves a blank screen with no cursor, which is the one
failure a terminal program must not have. Ctrl+C is not a restore path of its own: it reaches the
editor, the editor answers `Interrupt`/`Eof`, and the session ends through the same guard.

Leaving writes, in order: mouse reports off, bracketed paste off, cursor visible, attributes reset,
alternate screen off (which brings back the shell's screen exactly as it was). `scroll::vt::Vt` asserts
that in the tests: it keeps both screens and gives the shell's back.

## Tests

`cargo test -p wa-term scroll::` (also run by `bash scripts/fast.sh`, which tests `wa-term` whenever it
changes). The render tests drive the real seam - `Console::feed` with the bytes a terminal sends,
`Console::write` with output, `Console::frame` with a real `Editor` - and read a fixed-size virtual
terminal (`scroll/vt.rs`) instead of the escape bytes, so what is asserted is the screen a reader would
see: scroll position, follow mode, the marker, both folds, a resize, the wheel, the scrollbar, the
status row, the inline fallback and the restore. `scroll/settings.rs`, `scroll/keys.rs` and
`scroll/chat.rs` carry the unit tests for the knobs, the decoder and the scroll arithmetic.

## Wiring it to the process (not done yet)

The console is a library with no caller yet: the host's reader thread (`console_reader` in
`rust/wa-capabilities/src/host.rs`) is what owns the keys, the editor and the frames, and that file is
on this change's do-not-touch list. The integration is small and mechanical, and the seam was built for
it:

1. In `console_reader`, after `selection::take`, hand `keys` to `Console::feed` instead of walking
   bytes into `transcript`/`Editor`; feed `handled.forwarded` to the editor as today.
2. Replace `transcript.write` / `transcript.page` / hold / sync with `Console::write` / `feed`, and
   `layout_frame`'s transcript half with `Console::frame(&mut editor, width, height)`.
3. On start, `Guard::arm(mode)` and `install_panic_restore(mode)`; on teardown (`restore_input`),
   `Guard::leave`. Nothing else of the inline path changes: the box, the status line, the ticker, the
   menus and the rebuild row keep their rows.
4. Expose the mode to Lua so `wa chat --inline` and the footer hint can see it (one more `host.*`
   capability; the decision itself is already `Settings::mode`).
