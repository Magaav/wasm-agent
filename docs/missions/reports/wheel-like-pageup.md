# wheel-like-pageup — one wheel notch pages the transcript, as PageUp does

Branch `change/wheel-like-pageup`, base `78665117`, one commit: `ba51d7d0`. Committed locally and **not
pushed**, as this mission's brief says.

Victor (22/11): "scroll with mouse should behave exactly the same as pg up pg down from keyboard (which is
correct), same amount of scroll from both endings".

## The reading of "exactly the same", and why the smaller-step variant was not needed

Victor's own test settles it: "PageUp three times, note the top line; go back to the bottom; three wheel
notches up: the same top line." So **one notch = one PageUp**.

The measurement also shows there was no "same ends, smaller step" to preserve: both triggers already reach
the same ends because both call `Transcript::page` (`rust/wa-term/src/transcript.rs:434`), which clamps at
`lowest = start.min(bottom.min(0))` and `bottom.max(lowest)` and, at the bottom outside navigation, drops
the freeze and follows again (`transcript.rs:672-690`). Only the step differed: the keys took
`page_rows` — a third of the chat's rows, at least one (`transcript.rs:123`) — and the wheel took a fixed
three rows (`host.rs`, the wheel's transcript branch). So there is no second constant: the wheel now calls
the same `page_rows` the keys call.

## Measured on the base, in a real pty (80x40, an answer of 181 rows, a one-row box)

The chat gets 36 rows, so one page is 12 rows. First visible row of the transcript, from the bottom
(`row149` on screen):

| gesture | after |
|---|---|
| 3 PageUps | `row113` (36 rows up) |
| 3 wheel notches | `row140` (9 rows up — three a notch) |
| 20 PageUps | the chat's first row, and one more PageUp moves nothing |
| 20 wheel notches | `row089`, and one more notch moves it again (`row086`) |

So on the base the wheel moved a quarter as far per gesture and could not reach the top of the chat at all
— exactly Victor's complaint. `Ctrl+PageDown` (back to the bottom) works for both and is the harness's own
premise, checked in the test.

## What changed (`ba51d7d0`)

- `rust/wa-capabilities/src/host.rs:3873` — the wheel's transcript branch takes `page_rows(state)` and
  pages by it, the way the keys do, instead of `page(if up { 3 } else { -3 })`. The two key paths it now
  matches: `host.rs:4380` (the transcript's own nav) and `host.rs:4403` (the input box's PageUp/PageDown
  arm).
- `rust/wa-term/src/keymap.rs:467` — the Scrolling help text (see "Texts to approve").
- `rust/wa-capabilities/src/host.rs:5544` — `a_wheel_notch_pages_the_chat_exactly_as_pageup_does`, next to
  the paging test it extends.
- `scripts/test-wheel-pageup-pty.mjs` — the pty test (new, 11 checks).
- `scripts/fast.sh:899` — the row `wheel-pageup-pty`, right after `tui-chrome-pty`.

Item 2 of the brief is unchanged on purpose: the wheel over an input box with more lines than it shows is
still the box's (`host.rs:3863`, `input.wheel(up, 3)`). `scripts/test-tui-chrome-pty.mjs` still proves it —
`18 ok, 0 failed` on this build, including "the wheel over the box scrolls the draft" and "and the
transcript did not move".

## The tests, and that they fail before the change

**pty (`scripts/test-wheel-pageup-pty.mjs`)** — the real binary in a private tmux server, a local SSE
fixture that must have served the run, `env -i` with an allow-list, a scratch HOME that refuses to be the
real one:

- A: three notches up and three PageUps leave the same first row, and it is not the row the reader came
  from.
- B: 20 steps of either stop on the same first row, that row is the chat's first (the answer's own first
  line is on that screen), and one more step of either moves neither.
- C: from home, eight notches up leave the newest row behind; eight down come home (newest row on screen,
  nothing below it); eight up again land on the same row; and eight PageDowns from the same place end on
  the wheel's own row.

Same file, two binaries, nothing else different: base `7 ok, 4 failed` (A and the three B checks) —
`/tmp/wheel-base-final.log`; this build `11 ok, 0 failed` — `/tmp/wheel-fixed2.log`.

**unit (`host.rs:5544`)** — drives the host's own mouse path (`handle_mouse`) and the editor's own bytes
against the same 400-row chat, and compares the first visible row. On base it fails `left: 361, right: 352`
(the notch moved three rows where PageUp moved twelve); with the change it passes.

Wired in `scripts/fast.sh` (row `wheel-pageup-pty`, `WA_BIN="$bin"`, as `tui-chrome-pty` is). The unit test
runs in the `wa-capabilities` row of the same file.

## Verification I ran

- `flock -o ~/Work/missions/.suite.lock bash scripts/fast.sh` in the worktree: **385 checks, 384 passed, 1
  failed, 571 s**. `wheel-pageup-pty` pass 12.1 s, `tui-chrome-pty` pass, `rust wa-capabilities` pass, `rust
  wa-term` pass.
- The one failure, `install-guards`, is **pre-existing**: the same script on a plain export of the base
  commit (`git archive 78665117`) reports `72 checks, 6 failed`, the same five `upgrade:` messages and the
  same `/health` line, with and without `WASM_AGENT_IN_TURN`. No installer file is in this diff.
- `cargo test -p wa-term --lib`: 182 passed.
- `cargo test -p wa-capabilities --lib terminal_tests`: 7 passed, my new one among them.

## Limits, named

- **C is not discriminating.** Eight notches up and eight back down return to the same row at any step
  size, so C passes on the base too. It states the behaviour the brief asks for (both end following the
  newest row) and is paired with A and B, which do discriminate.
- **"Following" is read off the screen, not by a new answer.** A submit syncs the transcript itself
  (`host.rs:4459`, the Submit arm's `to_bottom`), so a submit could not tell how the reader got home. What
  the test asserts is the transcript's own rule for following (`transcript.rs:672-690`): at the bottom
  outside navigation, the freeze is dropped and the newest row is drawn with nothing below it.
- Measured at one window size (80x40) with a one-row box. A taller box or a run's status row pages fewer
  rows for both triggers, because both go through the same `page_rows`.
- I did not run the nightly gate (`scripts/test.sh`), and I did not run `scripts/test-discriminates.sh`
  itself; the base runs above are that check's evidence, done by hand with the same revert-only-the-code
  rule.

## Texts to approve

1. `/keybindings`, Scrolling: `the wheel: a page of the transcript, as PageUp/PageDown (over an input box
   with more lines than it shows: the draft)` — was `the wheel: the transcript three rows up or down (over
   an input box with more lines than it shows: the draft)`.

## Files

`rust/wa-capabilities/src/host.rs`, `rust/wa-term/src/keymap.rs`, `scripts/fast.sh`,
`scripts/test-wheel-pageup-pty.mjs`, `docs/missions/reports/wheel-like-pageup.md` — commit `ba51d7d0`
(the report follows in its own commit).
