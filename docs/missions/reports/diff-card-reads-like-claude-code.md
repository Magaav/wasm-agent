# diff-card-reads-like-claude-code - item 3, a changed line is readable on its band

Victor, 23/11, two screenshots: "we are quite distant from the Claude Code diff view experience. 1. our
block does not expand. 2. our block does not have a 1 line gap between it and the next block." The brief
has four items; THREE OF THEM WERE ALREADY LANDED and are green on main (see "already done" below), and
this mission changed only item 3.

## Item 3, as the brief words it

> READABLE ROWS: an added/removed row keeps its full contrast when the card is folded or unfocused (the
> screenshot's row was near-invisible). State the palette roles and show a screenshot-equivalent capture
> at the default theme.

## What was wrong, measured in a real terminal

The screenshot's row was unreadable because the band was painted as a FOREGROUND (38;2;18;48;28 as text
on black, 1.4:1). That was fixed before this mission. What was still wrong is what the eye meets next,
measured 27/11 in a 100x44 pty at the default theme, reading the escape sequences the terminal actually
received:

    added   fg 777777 on bg 12301c   3.20:1  "| 1 +"          <- the number and the +/- marker
    added   fg 6a9955 on bg 12301c   4.30:1  "# old note"     <- a COMMENT inside an added line
    added   fg 4eba65 on bg 12301c   5.83:1  "line_01 ="
    removed fg 777777 on bg 3a1620   3.56:1  "| 1 -"
    removed fg ff6b80 on bg 3a1620   5.83:1  "line_01 ="

Two pairs were under the 4.5:1 that plain text needs: the line number and the change marker were drawn
in the FRAME's colour (mdCodeBlockBorder), and a comment inside an added line reached 4.30:1.

## What changed (one commit, f20a9c4e)

1. `lua/core/cli_view.lua`, the lead of a diff body row is two colours instead of one: the frame glyph
   stays `mdCodeBlockBorder`, and the LINE NUMBER AND THE MARKER take the row's own role
   (`toolDiffAdded` / `toolDiffRemoved` / `toolDiffContext`). The marker is the row's change sign, not
   frame decoration.
2. `lua/core/cli_view.lua`, `toolDiffAddedBand` 12301c -> 0f2a18. On 12301c the darkest body colour a
   changed row can carry (`syntaxComment`) reached only 4.30:1; on 0f2a18 it reaches 4.62:1, and every
   other role on the band rises with it. `toolDiffRemovedBand` (3a1620) already cleared 4.5:1 (its worst
   pair is the same comment at 4.79:1) and is unchanged.

## The palette roles, and every ratio on a band at the default theme

Measured over the palette as the tree states it (WCAG 2.x relative luminance, default theme, background
black):

| role | hex | on added 0f2a18 | on removed 3a1620 | on black |
| --- | --- | --- | --- | --- |
| toolDiffAdded | 4eba65 | 6.25 | 6.49 | - |
| toolDiffRemoved | ff6b80 | 5.62 | 5.83 | - |
| syntaxComment | 6a9955 | 4.62 (was 4.30) | 4.79 | - |
| syntaxKeyword | 569cd6 | 5.22 | 5.41 | - |
| syntaxString | ce9178 | 5.82 | 6.04 | - |
| syntaxNumber | b5cea8 | 9.06 | 9.39 | - |
| syntaxFunction | dcdcaa | 10.89 | 11.30 | - |
| syntaxType | 4ec9b0 | 7.55 | 7.83 | - |
| toolDiffContext | 999999 | 5.40 | 5.60 | - |
| mdCodeBlockBorder (frame) | 777777 | 3.20 | 3.56 | 4.69 |

The frame glyph is the only thing on a banded row held to 3:1 - the rule a non-text element is measured
by - and it is named in the row as the frame.

## The screenshot-equivalent capture

`scripts/test-diff-card-contrast-pty.mjs` prints, for every glyph of every banded row on the screen, the
pair it was drawn with and its ratio, so the run IS the capture:

    added   fg 4eba65 on bg 0f2a18  6.25:1  "line_01 ="
    added   fg 6a9955 on bg 0f2a18  4.62:1  "# new note"
    added   fg b5cea8 on bg 0f2a18  9.06:1  "1"
    removed fg ff6b80 on bg 3a1620  5.83:1  "line_01 ="
    removed fg 6a9955 on bg 3a1620  4.79:1  "# old note"

## The rows

* `scripts/test-diff-card-contrast-pty.mjs` (NEW, 372 lines): a real pty, a real binary, the model played
  by a local SSE fixture. It creates a Python file whose first line carries a comment, then changes the
  comment (so one removed row and one added row BOTH hold a comment - the darkest body colour), then
  writes another file so the card is no longer the newest block. It reads the screen with
  `capture-pane -e` and checks, with no colour written into the check itself:
  1. a band is never a FOREGROUND (the screenshot's defect);
  2. no banded glyph is drawn faint;
  3. the frame glyph clears 3:1 and every other glyph clears 4.5:1 against the band under it;
  4. a changed line that carries a comment is among the measured rows;
  5. an OLDER card keeps both bands and the same ratios (the "folded or unfocused" half: a card is never
     folded now, so what is left to measure is a card that is no longer the newest block).

  ON MAIN (42eb4af5, same binary, main's own Lua): **3 failures** - `| 1 +` at 3.20:1, `# old note` at
  4.30:1, and the older card's marker still in the frame role. On this branch: **14 ok, 0 failed**.
* `tests/diff-view.lua` (+16 checks): the same rule at unit speed - every colour that can appear on a
  band must clear 4.5:1 against both bands, and the band's own sequence is now READ FROM THE PALETTE
  instead of written twice, so a palette change cannot disagree with the row. Pre-existing failure on
  both trees: "an unrecorded change says so instead of an empty diff" (needs host.exec; SKIPped in a Lua
  run, "the gate's binary run judges it") - identical on main, not this branch.
* `scripts/test-diff-card-pty.mjs` (23 ok, 0 failed): unchanged, still green - the lead split did not move
  a single number or column.

## Already done before this mission (items 1, 2, 4)

Verified on main `42eb4af5` by `scripts/test-diff-card-pty.mjs`, 23 checks, 0 failed: the card is drawn
OPEN with every line and bounded at 40 lines with ctrl+o; one blank row above and below it (also after a
resize and in `--continue`); `● Create(path)` / `Update` / `Delete` headings with the path shortened to
 the workdir. Nothing in this branch touches those.

## Rules kept

No release, no fleet update, nothing on a live peer. FACTORY rule 12: nothing installed, no edit to
`installed.txt`. The suite rule: no `scripts/fast.sh` plain run, no `test.sh`/`preflight.sh`, no
`wa land --until gate` - only the rows for the touched files (`WA_FAST_ROWS`), the two pty rows singly,
and `tests/diff-view.lua`. No environment knob was added to product code.

## Proposed FACTORY/HANDOVER text (for the orchestrator, not written)

> A colour pair that a reader must READ is measured, not chosen: a role drawn on a band is checked at
> 4.5:1 against it (WCAG AA for text), the frame's own glyph at 3:1, and the darkest body colour of the
> row (`syntaxComment`) is the pair that decides the band. `tests/diff-view.lua` holds the arithmetic and
> `scripts/test-diff-card-contrast-pty.mjs` holds the screen; a palette change that breaks either is a red.
