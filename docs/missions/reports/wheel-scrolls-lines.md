# wheel-scrolls-lines — the wheel moves the chat one row per event

Branch `change/wheel-scrolls-lines`, base `c6f890e3`, four commits: `df0a0982`, `2e945cf8`,
`49f57442`, `f97cc586`. Committed locally, **not pushed**, as the brief says.

Victor (22/11 20:30Z): "the mouse scroll on TUI chat content is jumping way further than the pg up/down
which ticks 1/3 of the content by each tick", then "better than follow page up/down, scroll from mouse
should scroll line by line". This **replaces** his 22/11 wish that one notch equal one PageUp, which
`change/wheel-like-pageup` (`ba51d7d0`) built one round earlier.

## The premises, re-measured before any code (rule 9)

| brief's premise | what I measured |
|---|---|
| `host.rs:3872-3893`: every `Mouse::WheelUp/WheelDown` over the chat moves a page | true on the base: the arm is `host.rs:3872` and it called `page_rows(state)` at line 3891 (`git show c6f890e3:rust/wa-capabilities/src/host.rs`; `fn page_rows` at 4117) |
| `page_step` = a third of the chat, at least one row | `rust/wa-term/src/transcript.rs:123`: `(area / 3).max(1)` |
| a terminal sends SEVERAL reports per notch; foot's `multiplier=7.0` | `~/.config/foot/foot.ini:11` (`[scrollback]`, `multiplier=7.0`), `foot 1.28.0`; `man 5 foot.ini`: "multiplier — Amount to multiply mouse scrolling with. ... Default: 3.0". **The COUNT of reports one notch makes was not captured** — no hand turned a wheel from this session, and foot's source is not on this node. What is measured is what the host does with ONE report (below); the pty row writes seven reports to stand for the notch. |
| wa chat never enters the alternate screen, so foot's multiplier applies | true: the only `\x1b[?1049h` under `rust/` is `rust/wa-term/src/scroll/screen.rs:36` (the fullscreen mode); the inline console turns on `?1002h ?1003h ?1006h` only (`rust/wa-term/src/selection.rs:27`) |
| the wheel over a tall input box already moves 3 rows per event — leave it | `host.rs:3881`: `input.wheel(up, 3)`, in the arm before the transcript branch. Untouched; `scripts/test-tui-chrome-pty.mjs` proves it (18 ok, below). |

Two documentation claims were already wrong on the base and are fixed under `f97cc586`:
`docs/HOST.md:628` and `docs/TERMINAL.md:9` both said "the wheel pages the chat".

## What changed

- **`df0a0982` — the behaviour.** `rust/wa-capabilities/src/host.rs:3895`: the wheel's transcript branch
  is `state.transcript.page(if up { 1 } else { -1 })` instead of `page_rows(state)`, with the comment
  above it (`host.rs:3887-3894`) saying why. It is the same `Transcript::page` the keys call
  (`rust/wa-term/src/transcript.rs:434`), so the clamp at the top and at the bottom and the return to
  following the newest output are the keys' own (`transcript.rs:675-690`), one row at a time.
  PageUp/PageDown are untouched and still take `page_rows`: `host.rs:4402` (the transcript's nav) and
  `host.rs:4425` (the editor's PageUp/PageDown arm).
- **`2e945cf8` — `/keybindings`.** `rust/wa-term/src/keymap.rs:467`, the Mouse surface's Scrolling row
  (verbatim in "Texts to approve").
- **`49f57442` — the pty row.** `scripts/test-wheel-lines-pty.mjs` (new, 12 checks) replaces
  `scripts/test-wheel-pageup-pty.mjs`, whose A and B checks asserted the behaviour this round reverses.
  Every check that still holds is kept (the fixture served the run; the transcript is several screens
  long; the wheel stops on the chat's first row and no further; coming home to the newest row); the "same
  first row as three PageUps" checks become "one report is one row", "a notch is seven rows" and "PageUp
  is still a third". `scripts/fast.sh:908-914` runs it as the row `wheel-lines-pty`.
- **`f97cc586` — the docs** named above.

Item 2 of the brief is in `df0a0982`: `a_wheel_notch_pages_the_chat_exactly_as_pageup_does`
(`host.rs:5764` on the base) becomes `one_wheel_event_moves_the_chat_one_row` (`host.rs:5767`). It keeps
the old test's PageUp half (the `\x1b[5~` sequence is PageUp's, a page is 12 rows in an 80x40 window,
PageUp moves exactly that) and adds the three scenarios the brief names: one event = one row; a burst of
seven events between two frames = seven rows; nine up then nine down = the bottom and following again.

## Measured, in a real pty, on the binary this branch built

`/home/victor/wasm-agent/target/m-wheel-scrolls-lines/release/wa`, rebuilt from `f97cc586` with the
prepared code-mode assets (`WA_CODEMODE_BUILD_ASSETS=<git-common-dir>/codemode-assets/pi-1.2.0-quickjs-3.6.2`,
78 548 680 B, `wa --version` → `wasm-agent f97cc586`). Nothing installed; `~/.local/bin` and
`installed.txt` untouched (rule 12 of the factory).

`WA_BIN=<that binary> node scripts/test-wheel-lines-pty.mjs` — the real binary in a private tmux server,
80x40, a local SSE fixture that must have served the run, a scratch HOME that refuses to be the real one:
**12 ok, 0 failed**.

| gesture | measured |
|---|---|
| one mouse report up | the first row moves one line up |
| one foot notch (7 reports) | 7 rows up |
| one PageUp | 12 rows up — the chat is 36 rows on screen, a third |
| reports far past the top | stops with the chat's first row (`row001`) on screen; one more report moves nothing |
| 8 reports up from home | the newest row off screen, the "`↓ N more lines (PgDn)`" hint on |
| 8 reports down | the newest row on screen, no hint, the same first row home was on |

`WA_BIN=<that binary> node scripts/test-tui-chrome-pty.mjs`: **18 ok, 0 failed**, including "the wheel
over the box scrolls the draft (two events up: lines 23..34)" and "and the transcript did not move" — the
tall input box keeps its three rows per event.

## That the tests fail on the old code (rule 16)

By hand, with `scripts/test-discriminates.sh`'s method: only the one non-test line of `host.rs` reverted,
rebuilt, both tests run, then `git checkout -- rust/wa-capabilities/src/host.rs`, a rebuild, and both tests
run again to prove the tree is back (`restored: True`, and `git status` clean apart from this report).

- **pty, on the old code: 9 ok, 3 failed.** The three that fail are "one mouse report moves the chat ONE
  row", "a foot notch (7 reports, multiplier=7.0) moves the chat 7 rows, not screens" and "eight reports up
  leave the newest row behind" (which also asserts the row it landed on). On this build: 12 ok, 0 failed.
- **unit, on the old code**: `one wheel event moves the chat one row, not one page` fails
  `left: 352, right: 363` — one report moved 11 rows (a page of the chat in that fixture) where one row was
  asserted. On this build: pass.

## The suite

`flock -o ~/Work/missions/.suite.lock bash scripts/fast.sh` in the worktree, with the assets-built binary:
**395 checks, 0 failed, 0 skipped, 534 s** (`fast path ok`), `wheel-lines-pty ok (17804 ms)` among them.

`cargo test -p wa-term`: 189 passed (184 + 4 + 1 across the crate's test binaries).
`cargo test -p wa-capabilities host::terminal_tests`: 8 passed, the new one among them.

My own mistake, named: the first suite run reused a binary I had built with `WA_CODEMODE_ALLOW_EMPTY=1`
(no code-mode assets) and eleven `codemode_not_enabled` rows failed for that reason alone. I rebuilt with
the prepared assets and re-ran the whole suite; that is the run above.

## Texts to approve (operator- and model-facing, verbatim)

1. `/keybindings`, pointer / Scrolling — was `the wheel: a page of the transcript, as PageUp/PageDown
   (over an input box with more lines than it shows: the draft)`, now
   `the wheel: one row of the chat per event, so one notch is a few lines (your terminal's scrollback
   multiplier: seven with the 7.0 in foot.ini); over an input box with more lines than it shows: the
   draft`
2. `docs/HOST.md` — was "The wheel pages the chat.", now "The wheel moves the chat **one row per mouse
   report** - a notch of the wheel is the several reports the terminal sends for it (foot multiplies them
   by its `[scrollback] multiplier`) - and PageUp/PageDown keep their third of it."
3. `docs/TERMINAL.md` — was "and the wheel pages the chat.", now "and the wheel moves the chat one row
   per mouse report (a notch is several: the terminal's `multiplier`)."

## Limits, named

- **The reports-per-notch count is not captured.** The host's per-report behaviour is measured; how many
  reports one notch is, is foot's `multiplier` and its man page, and the pty row's seven is that reading,
  not a capture. A touchpad sends more. Victor's own test ("roll one notch: a few lines, 7 with your foot
  multiplier=7") is the acceptance.
- **`a notch is not a page any more` does not discriminate**: on the old code a notch was seven pages,
  which is also "not a page", so it passes there too. It states the relationship the change is about and is
  paired with the two checks above that do fail.
- **The fullscreen mode is out of this brief and untouched.** `rust/wa-term/src/scroll/` keeps its own
  step (`WA_TUI_WHEEL_LINES`, `auto` = three, `rust/wa-term/src/scroll/settings.rs:97`), whose comment
  calls three "the inline console's own step". That comment was already loose on the base (the inline
  console's chat step was a page, not three) and is loose differently now (one); it is a separate mode and
  I left it, naming it here rather than silently redefining another surface's default.
- **I did not run `scripts/test-discriminates.sh` itself**; the discrimination above is its method done by
  hand, with the run's own output kept, and the landing gate will redo it.
- `~/.local/bin/wa` on this node is whatever it was; I did not install, and nothing here changes it until
  a landing.
