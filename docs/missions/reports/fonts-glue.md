# fonts-glue — the glued icon set only where wa Icons is the face drawing it

Mission: fonts-install item 5 (Victor, 21/11). Branch `change/fonts-glue`, base `23340c03`
(`change/fonts-install`), worktree `/home/victor/Work/missions/fonts-glue/wt`.
Commits: `9d2fe8de` (the measurement and the decision), `603bd58a` (`/icons` keeps the reason),
`ce58cadb` (the default is asked, not recorded: assertion, kitty fixture, wording).

## The bug, re-measured on this node

The record said wa Icons was installed, so the glued set was chosen for **every** window, including
windows that had started before the setup rewrote their config and were still drawing the Nerd face.
`lua/core/icons.lua` asked `M.installed()` and nothing else; a window older than the edit got gap `""`
over glyphs wider than their cell — Victor's "bottom is glued" (21/11 ~10:50).

Facts measured here before any change (`23340c03`):

| fact | measured value |
| --- | --- |
| the record | `~/.wasm-agent/setup/fonts.json`, `"wa Icons": true`, foot row `~/.config/foot/foot.ini`, `at` `2026-11-21T13:24:41Z` |
| when the setup wrote foot.ini | `stat -c %Y` = `1795265182` = 21/11 10:26:22 -03 |
| foot windows alive | three, started `1795221155`, `1795254445`, `1795259917` — **all older than the write** |
| the pre-edit face | `~/.config/foot/foot.ini.wa-backup`: `font=JetBrainsMono Nerd Font:size=9` |
| a process's start time | `stat -c %Y /proc/<pid>` == `btime + starttime/HZ` exactly (`1795171050 + 8886745/100` = `1795259917`) |
| which face fontconfig gives U+F0766 for a "JetBrains Mono" stack | `JetBrains Mono Nerd Font,JetBrains Mono NF` — **not** wa Icons |
| which face fontconfig gives for the family `wa Icons` | `wa Icons` (the font is installed and resolvable) |

The old path's own output, captured on `23340c03` with a stubbed record (the golden this branch keeps
honest): `record set=wa | source=default (wa setup fonts installed wa Icons)` — with, in that same
process, no terminal at all. That line is the bug.

## How it decides now

`lua/core/icon_face.lua` (`9d2fe8de`, 383 lines) answers one question — *is wa Icons the face drawing the
icon code points in the terminal THIS process runs in* — in three steps, each of which can answer "cannot
tell", and "cannot tell" is never "yes":

1. **Which terminal, and when it started.** One shell script walks `/proc` from this process up its
   ancestors to the first `comm` that is an emulator (foot, footclient, alacritty, kitty, ghostty,
   wezterm/wezterm-gui), and stats every candidate config in the same pass — one exec per process, cached.
2. **Which face draws the icon code points.** When the config names the icon face itself (foot's font
   list, kitty's `symbol_map`, ghostty's `font-codepoint-map`) the config says so, read through the
   setup's own `already_a2`, and the font is confirmed resolvable (`fc-match -f %{family} 'wa Icons'`).
   Terminals that take their fallback from fontconfig (alacritty, wezterm, GNOME Terminal, Windows
   Terminal) are asked fontconfig's own question:
   `fc-match -f %{family} '<family>:charset=f0766'`.
3. **Whether the running window loaded that config.** Window start time vs config write time, in whole
   seconds; the same second cannot be ordered and is treated as "cannot tell".

Outcomes: `glued = true` only when all three hold; otherwise the **spaced** set, chosen by the same
fontconfig question — a face that has U+F0766 draws its own wide Nerd glyphs (`nerd`), one that does not
leaves the code point to a fallback this node cannot name (`unicode`). An unidentifiable terminal, a
fontclient window, an unreadable config, a `/proc`-less host and a missing wa Icons font all land on a
spaced set with a named reason.

Why this shape rather than the brief's option (b) (a terminal query, ~50 ms): the two clocks are already
there, the same exec that walks the ancestors also stats the files, nothing is asked of the tty, and a
terminal that does not answer cannot stall a start-up.

`lua/core/icons.lua` (`9d2fe8de`) keeps the order (session `/icons` > `WA_ICONS` > config `icons =` >
what this terminal draws) and now asks `icon_face.face` for the default instead of `M.installed()`.
`lua/core/cli_view.lua` (`603bd58a`) stops overwriting the reason at load: `use_icons()` replaced it with
the placeholder `"use_icons"`, so `/icons` could say WHICH set but never WHY — measured, then fixed.

## Texts to approve (verbatim, from a real run on this node)

The lines `/icons` prints (chat.lua keeps its `  icons <set>  (<reason>)` shape). The old-window and
new-window lines below were produced by `icon_face.face` with the real `foot.ini`, the real fonts and the
two clocks measured above:

1. old foot window:
   `  icons nerd  (this foot window started 1h 27m before wa setup fonts wrote /home/victor/.config/foot/foot.ini, so it is still drawing the face it loaded then; 'JetBrainsMono Nerd Font' draws the icon code points, and its glyphs are wider than their cell)`
2. new foot window:
   `  icons wa  (wa Icons draws the icon code points in this foot window, which started 13m after wa setup fonts wrote /home/victor/.config/foot/foot.ini)`
3. same second as the write:
   `  icons nerd  (this foot window started in the same second as wa setup fonts wrote <config>, so which face it loaded cannot be told; '<family>' draws the icon code points, and its glyphs are wider than their cell)`
4. no terminal in the ancestry:
   `  icons unicode  (no terminal emulator is in this process's ancestry (bash <- systemd))`
5. config unreadable:
   `  icons unicode  (the config this foot window loads could not be read (<path>))`
6. wa Icons no longer installed:
   `  icons nerd  ('wa Icons' is not installed for this user: fontconfig answers 'Some Other Font' for it, so this foot window cannot be drawing it; '<family>' draws the icon code points, and its glyphs are wider than their cell)`
7. fontconfig terminal (alacritty):
   `  icons nerd  (the config this alacritty window loads does not give the icon code points to wa Icons (fontconfig answers 'JetBrains Mono Nerd Font'); 'JetBrains Mono Nerd Font' draws the icon code points, and its glyphs are wider than their cell)`
8. footclient window:
   `  icons unicode  (this is a footclient window: the foot server draws it, and it read its config when the SERVER started, which this window does not date)`
9. host without `/proc`:
   `  icons unicode  (the terminal this process draws in could not be measured (this host has no readable /proc, so a process's start time cannot be read here))`

Unchanged: `  icons <set>  (environment WA_ICONS)`, `(config <path>)`, `(/icons <set>)`, and
`  choose: wa (wa Icons, glued), nerd, unicode, ascii`.

## Tests, and where they run

- `scripts/test-icon-face.lua` (new, `9d2fe8de`, 44 checks): the walk script and its quoting, the parse of
  the script's words, the window-against-config rule, the spaced fallback, and **the walk across two real
  processes** — a copy of this machine's shell named `foot` in a scratch directory, with the walk running
  as its child, asserting the `comm`, the pid, the start time and the config's write time it reports. A
  host without `/proc` (or without a shell to copy) is a named **skip**, never a pass.
- `scripts/test-icons.lua` (changed, `9d2fe8de`/`ce58cadb`, 224 checks): the brief's three fixtures
  through `icons.resolve` — new window → `wa` glued; window older than the write → `nerd` spaced with the
  space; unidentified terminal → `unicode` — plus same-second, missing-font, alacritty, footclient,
  unreadable-config, a kitty `symbol_map` (and a stale whole-plane one), and the assertion that
  `cli_view` keeps the resolved reason at start-up. The old "resolve==wa iff the record says installed"
  assertion is gone: it wrote the bug down as a test.
- Wired at `scripts/test.sh` line 1996 (`9d2fe8de`), beside the icons row:
  `WA_SCRIPT=scripts/test-icon-face.lua "$BIN" --db "$DB.icon-face" | grep "icon face: ok"`.
- `bash scripts/test-discriminates.sh 23340c03 --repo .` (`WA_BIN=$(command -v wa)`): **2 discriminating,
  0 blocking** — `scripts/test-icon-face.lua` and `scripts/test-icons.lua` both fail on the base.

Rows run here, with the installed node binary and `WASM_AGENT_LUA_ROOT=<worktree>` (this change is Lua
only; no release build was made): `test-icons` 224 checks ok, `test-icon-face` 44 ok, `test-cli-view`
552 ok, `test-font-setup` 180 ok.

## What I verified, and what I did not

Verified: the decision for each of the cases above, through `resolve()` and through a real node process;
the /proc start-time identity; fontconfig's own answers on this node; the cross-process walk; the four Lua
rows and the discriminating verdicts. Never touched: the operator's `~/.config` or `~/.wasm-agent` (every
fixture injects its reader/query, and the cross-process test works in a scratch directory it removes).

Not verified: **the pixels** — I cannot open foot windows, so the "1 px before its digit" and the "space
before each number" are Victor's to confirm; and a live foot ancestry, because in this session `wa` runs
under the agent runtime (`wa <- bash <- systemd`), where the walk correctly answers "no terminal". The
whole gate (`scripts/test.sh`) was not run: it needs a release build. macOS/Windows have no `/proc` and
therefore land on the spaced set — not measured on either.

## Premises of the brief that were wrong or imprecise

- The brief's "(a) compare the terminal process start time with the time setup edited that terminal's
  config" is right, and cheaper than the calendar suggests: the start time is the `/proc/<pid>` mtime.
- "the RECORD says wa Icons is installed" was not the only reason `/icons` could not explain itself:
  `cli_view` threw the reason away at load (`603bd58a`).
- `/icons` also needed a fix for the reason to reach the operator at all (same commit).
- The setup's edit makes wa Icons the face only where the config names the icon face (foot, kitty,
  ghostty). For alacritty, wezterm, GNOME Terminal and Windows Terminal the face is fontconfig's choice,
  and on this node fontconfig prefers the **Nerd** font — those windows are now the spaced nerd set,
  which the setup's own "already set up" would have called done.
- "an OLD foot window (opened before 21/11 ~10:00)": foot.ini was written at **10:26:22 -03**, so the
  threshold is ~10:26.

## Pre-existing issues named (not fixed here)

- `scripts/test-discriminates.sh` gives a Lua row `HOME == WASM_AGENT_HOME` (its scratch home), so
  `scripts/lib/scratch-home.lua` refuses to run (`REFUSED ...`, exit 2) and the runner has no skip marker
  for that word: the row comes back `unclassified` and **blocks**. Any branch that touches
  `scripts/test-font-setup.lua` therefore blocks on the harness, not on its own tests. I reverted a
  cosmetic label fix in that file because of it: line 696 still says an installed record "is what makes
  the wa icon set the default", which after this change is only one of two conditions.

## Harness evaluation

- **What hurt**: there was no way to run a Lua row inside a live terminal. `host.exec` children inherit
  this node's ancestry (`wa <- bash <- systemd`), so the one fact this mission turns on — which emulator
  draws the icons — could only be reproduced by copying `bash` and renaming it `foot` in a scratch
  directory. Proposed fix: a documented terminal fixture in the contract host (a variable that only moves
  the `comm` the walk reads, e.g. `WASM_AGENT_FAKE_TERM=foot`), judged by
  `scripts/test-contract-host.lua`. Step delta: ~6 → 2 for the cross-process case.
- **What hurt**: `scripts/test-discriminates.sh` hands a Lua row `HOME == WASM_AGENT_HOME`, so
  `scripts/lib/scratch-home.lua` refuses to run and the row comes back `unclassified`/**blocking** —
  an edit to `scripts/test-font-setup.lua` cannot land on this harness. Proposed fix: give the row a
  scratch home below its own root, or read a `REFUSED ` line as the `skipped` verdict the runner
  already has for `SKIP `. Step delta: a blocked row → 0 (one revert of a correct label fix was the cost).
