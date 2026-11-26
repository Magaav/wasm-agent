# copied-notice-floats - the notice floats over the chat, centred, and moves nothing

VERDICT: **done and verified**. Branch `change/copied-notice-floats`, base `origin/main` 6b6afc72,
one commit (d200ac2e) plus the evidence in this file. The transient TUI message is an OVERLAY now:
painted over the region's top row (the row under the pinned request while that one holds row 0),
centred, reserving no row - so nothing else on the screen moves for it, when it appears or when it
goes.

## The cause, as measured on the base

`Transcript::view_at` (`rust/wa-term/src/transcript.rs`) computed `notice_rows = usize::from(notice_row.is_some())`
and folded it into `reserved`, which it then passed to `paint` as the chat's top offset: the region
was one row SHORTER while the message showed. Following the bottom, that costs the invisible top
row; frozen (scrolled up, which is where "one row" is visible), the top-anchored view moved the
whole conversation down a row and back, twice per copy. `notice_line` right-aligned it one column
short of the edge.

## The change (what the diff shows)

| file | what |
| --- | --- |
| `rust/wa-term/src/transcript.rs` | `view_at` reserves only the pin; the message is painted over one assembled row through the new `over(row, start, text)` (cells-of based, escapes kept); `notice_line` is centred, `(width - len) / 2`; `notice_shown: bool` → `notice_row: Option<usize>`; `on_notice` answers for that row and `on_pin` is `row == 1` again |
| `rust/wa-capabilities/src/host.rs` | comments only (`say`, `flush_editor_notice`, the dismiss gesture, the sticky-error rule) |
| `docs/TERMINAL.md` | new section: "The notice floats over the chat" |
| `scripts/test-pinned-request-pty.mjs` | the notice checks are the new order, plus byte-identical checks around it |

`git show --stat d200ac2e` is the citation for every line above: 4 files, 255 insertions, 65
deletions.

## Rows

`cargo test -p wa-term`: **225 passed, 0 failed** (the 220 that were there, one replaced by name -
`the_notice_sits_above_the_pinned_request_and_goes_after_its_time` → 
`the_notice_floats_under_the_pinned_request_and_never_moves_the_chat` - and four new: the bottom
case, the centring, the pin order inside the first, and the copy icon's row).

Pty rows with this tree's own binary (`/home/victor/wasm-agent/target/m-copied-notice/release/wa`):

| row | verdict |
| --- | --- |
| `scripts/test-pinned-request-pty.mjs` | 32 ok, 0 failed |
| `scripts/test-tui-chrome-pty.mjs` | 18 ok, 0 failed |
| `scripts/test-jump-to-bottom-pty.mjs` | 14 ok, 0 failed |
| `scripts/test-reflow-blocks-pty.mjs` | 32 ok, 0 failed |

### The full fast path on this branch: 143 checks, 141 passed, 2 failed, 0 skipped

Both failures are the two Rust rows, and both are PRE-EXISTING flakes of this machine, named:

- `rust wa-capabilities` (exit 101) - the same five tests that fail on every branch, identified in
  `docs/missions/reports/wa-term-own-program.md` (the capability inventory row and four
  `operations::*` rows). The same row fails with exit 101 in fast runs of wt69 and wt86.
- `rust wa-term` (exit 101) - `the_unknown_font_line_is_said_once_and_icons_wa_survives_a_restart`
  at `wa-term/tests/icons.rs:202`: a pty test that spawns the node, restarts it and counts a notice
  line, with 10-30 s deadlines. The **exact same test at the exact same line** fails in fast runs of
  `wt81` (2026-11-25T10:29) and `wt90` (2026-11-25T22:20), neither of which contains this change;
  and on this branch it passed **5 of 5** times run alone, and passed in `cargo test -p wa-term`.
  It goes red when the machine is loaded (that run compiled `wa-capabilities` for 203.2 s while
  eight Lua rows ran).

Nothing about the notice is in either failure.

## What this branch does not do

No model-facing change (no prompt, no request byte), no release path, nothing installed. The
fullscreen console's own message (`scroll::chat`/`screen`) is untouched: this is the inline
transcript's notice, which is the one Victor saw flicker.
