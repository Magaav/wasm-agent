# wa-fonts - wa's look: JetBrains Mono + wa Icons (A2)

Mission: ship Victor's 19/11 decision - wa draws JetBrains Mono with its own "wa Icons" face, the icons
fill their cell with a 1 px right margin and the value is GLUED - and install it without asking.

Base: 13247bdb (origin/main). Branch change/wa-fonts. Six items, one commit each.

## What shipped, by item

| item | commit | what it does |
|---|---|---|
| 1 | 322bf740 | `scripts/build-wa-icons.py`: reproducible A2 builder from pinned sources; the built font, JetBrains Mono, the two licences and a manifest under `assets/fonts/`; `tests/test-wa-fonts.mjs` parses the committed sfnt itself (no fontTools, no network). |
| 5 | 5218f2eb | the window embeds both faces: `ui/fonts.css` + `ui/fonts/`, `wa-capabilities` answers `font/ttf` for the served faces (`font/woff2` too, if one is ever staged), `--font` leads with JetBrains Mono. The same commit FIXED a false claim from item 1 (below). |
| 5 (refine) | 3f5bae64 | the served copies ARE the .ttf files the installer needs, so no face ships twice (570 KB of duplicate removed). |
| 4 | 76157aaf | `lua/core/icons.lua`: one table, four sets (wa \| nerd \| unicode \| ascii), `/icons <set>`, `WA_ICONS`, config file, and the default read from the setup's record. Nine context states in wa/nerd/unicode. |
| 3 | edc40dd4 | `wa setup fonts [--undo] [--dry-run] [--verbose]`: per-user install (Linux/macOS/Windows paths), a known terminal's config edited ONLY when its face measurably cannot draw wa's icons, backup before every write, one line after, undo. |
| 3 (all eight) | b0cbc329 | the brief lists EIGHT terminals; the first version shipped five. Windows Terminal (JSON, face under defaults) and GNOME Terminal (gsettings, old value as the backup) added; iTerm2 refused BY NAME because its profiles are a binary plist, with the setting to change by hand in the refusal. |
| 2 | 429ca0fb | both release bundles carry the faces and the licences: Linux (whole `ui/`), Termux `RL_UI_ASSETS`, Windows installer/package/packaging lists. |
| 3+5 | 1500b9d8 | the installer runs `wa setup fonts` with no prompt; `--glyph-font` leads with "wa Icons"; the writer and the reader of the setup record name the same path (bug, below). |

## The A2 numbers, as the test asserts them

Measured from `JetBrainsMono-Regular.ttf` (not assumed): upm 1000, advance 600, cap height 730, hhea
1020/-300. One cell at size 9 is 7.2 px, so 1 px = 83 units; A2 = size = right edge = 600-83 = **517**,
ymid = **365**, advance = **1229/2048 = 0.600 em** for every icon (that is what "glued" means).
Written in the source's 2048-unit em so each outline is transformed once.

The set is the **14** code points `cli_view`'s GLYPH table draws - the prototype's list also carried
`md-check_circle`, its outline and `md-check_bold`, which no row draws, so they are not shipped.

## Bugs found and fixed in flight

1. **The reproducibility claim was false** (item 1, fixed in 5218f2eb). fontTools stamps `head.modified`
   with the wall clock as it saves, and head times have ONE-SECOND resolution - the two builds that
   "proved" reproducibility had landed in the same second. Measured: three builds, three different
   sha256. `recalcTimestamp=False` plus the pinned epoch fixes it, and the builder now PROVES the claim
   where it makes it (a second build, compared byte for byte).
2. **The context ball was one slot low** (item 4). `BALLS` took the nine states as they come, but
   `context_ball` indexes the EIGHT slices, so 93.75% drew the seventh slice.
3. **`terminals(home)` ignored its own home** (item 3). It consulted `XDG_CONFIG_HOME` even when handed
   a scratch home, so a caller asking "what would this machine do for THAT home" got the operator's real
   paths. This is the incident below.
4. **The ini edit appended a second font line** after replacing the first (a replaced line did not count
   as inserted), and wezterm's family was read only from a plain table, not from
   `font = wezterm.font({ family = ... })`.
5. **The icon default read the wrong file** (1500b9d8). `icons.lua` read `<data>/fonts.json` while the
   setup writes `<data>/setup/fonts.json` - one directory apart, invisible to either module's own tests,
   so a node that had just installed wa Icons still drew the unicode set. Found by running the command
   end to end, not by reading it.

## The operator's own config was modified, and how it was put back

While testing item 3, this mission's test wrote **`/home/victor/.config/foot/foot.ini`** through bug 3.
It was found immediately (the test's own assertion failed), and the damage was three injected
`font=JetBrains Mono:size=11:charwidth=6:icons=wa Icons` lines plus one replaced `font=` line.

**The backup could not be used to restore it**: repeated runs of the buggy path had overwritten
`foot.ini.wa-backup` with already-edited bytes, which is exactly what the first `--undo` "restored".
The file was reconstructed by removing the three injected lines and restoring the replaced one to
`font=JetBrainsMono Nerd Font:size=9`; the result is **byte-identical to
`/usr/share/omarchy/config/foot/foot.ini`**, the default Omarchy ships, which is what the file held
before (584 bytes, verified with `diff`: no difference). The damaged copy is kept at
`/tmp/foot.damaged.ini` and the reconstruction at `/tmp/foot.restored.ini` for inspection.

VERIFIED AFTERWARDS: `diff` of the live file against the Omarchy default reports nothing; no
`*.wa-backup` remains anywhere under `~/.config`; kitty's config still carries its 2026-11-05 mtime.

The guards that now exist: an explicit `home` decides EVERY path (`font_setup.terminals`), and
`scripts/test-font-setup.lua` refuses to run if any path it is about to edit is inside the operator's
real `~/.config` - it exits 2 rather than writing.

## Tests, and where they are wired

- `tests/test-wa-fonts.mjs` (71 checks) - wired in `scripts/test.sh` at `gate_run node tests/test-wa-fonts.mjs`.
  Parses the committed sfnt with a DataView (no fontTools, no venv, no network), asserts A2's numbers for
  all 14 glyphs, that the font's code points are exactly `icons.lua`'s wa set, the manifest hashes, the
  served copies being byte-identical twins, and every bundle list carrying all five files.
- `scripts/test-icons.lua` (197 checks) - wired next to the cli-view row. Renders the same run row and
  footer through each of the four sets and compares CELL widths (the glued row is exactly its gapped icons
  narrower), asserts the ladder never steps down, that every unicode icon is BMP, and drives
  `/icons`, `WA_ICONS` and the config file in precedence order.
- `scripts/test-font-setup.lua` (69 checks) - wired after it. Runs on a scratch home: the three OS font
  paths, the opt-out, a complete and a truncated bundle, foot/alacritty/kitty/wezterm edits as BYTES,
  backup content, undo, the record, the unknown-flag refusal, and that the writer and reader of the
  record name the same file.
- `scripts/test-cli-view.lua` (546/551 checks) now PINS the nerd set, because its assertions are the
  exact characters wa drew on 19/11; pinning them keeps them exact instead of derived from a scratch
  home's default.
- Rust: `wa-capabilities content_type` (the new `fonts_have_their_own_type`) and `wa-term status_bar`
  both pass. `scripts/test-command-parity.cjs` (62 checks) and `scripts/check-deploy-shipped.mjs`
  (185 checks) pass.
- Termux: `scripts/test-termux-bundle.sh` 42 passed / 0 skipped, and `scripts/test-termux-update.sh`
  green, with the fixtures mirroring the new asset list.

All three new test files fail on the base: they exercise `lua/core/icons.lua`, `lua/core/font_setup.lua`
and `assets/fonts/`, none of which exist there.

## Verified end to end on this node

`wa setup fonts` on a scratch home with a fixture `foot.ini`:

    wa setup fonts: foot -> JetBrains Mono (was Source Code Pro:size=11; backup .../foot.ini.wa-backup)
    ... the other four terminals left alone, each with its reason

then: three faces in `~/.local/share/fonts`; `foot.ini` carrying
`font=JetBrains Mono:size=11:charwidth=6:icons=wa Icons`; the backup holding the ORIGINAL bytes; the
record written; `icons.resolve()` answering `wa (default (wa setup fonts installed wa Icons))`; and
`wa setup fonts --undo` restoring `foot.ini`, removing the three files and the record.

## Review finding (21/11): a Nerd face was exempted, and that is the complaint itself

`draws_icons()` asked "can this font draw the md-* code points" - and **every Nerd font can**. So foot
on `JetBrainsMono Nerd Font` (Omarchy's default, and Victor's own) was left untouched and the icons kept
coming from the Nerd face at Nerd metrics, one space wide: exactly the spacing A2 replaced. Victor's
19/11 ~10:20 decision is later than the 09:45 "only when the font lacks Nerd glyphs" line, and it means
wa Icons draws those code points, which a terminal only does when its **primary** face does not carry
them itself.

Fixed in `c64c32b8`. The question is now "is this terminal already on the A2 pair"
(`M.already_a2`: primary face JetBrains Mono **and** wa Icons named). A Nerd family fails it and is
switched; a terminal already on the pair is left alone, so a second run still changes nothing. The value
is the pair in each terminal's own syntax, **keeping the operator's size**:

    foot          font=JetBrains Mono:size=9, wa Icons:size=9
    GNOME         'JetBrains Mono 9'
    the others    JetBrains Mono

The old value was wrong twice over: it wrote `icons=wa Icons`, which is **not foot syntax**
(foot.ini(5) takes a comma-separated list), and it replaced the operator's size with a fixed 11.

Two more defects this found:

6. **A half undo.** The second (no-op) run rebuilt the record from its own rows and dropped the backup
   of the edit still in effect, so `--undo` restored 0 configs while removing the fonts. The previous
   run's backup is now carried forward; verified end to end (two whole runs, then undo, then `diff`
   against the Omarchy file: byte-for-byte identical).
7. **`already_a2` had to distinguish a list from a family.** foot's comma form is split before the
   primary face is judged, so `"JetBrains Mono:size=9, wa Icons:size=9"` reads as set up while
   `"JetBrainsMono Nerd Font:size=9"` does not.

Test: `scripts/test-font-setup.lua` (117 checks, was 100) uses **the real Omarchy foot.ini bytes** as its
fixture — copied into the scratch tree from `/usr/share/omarchy/config/foot/foot.ini`, never
`~/.config`. Before = the Nerd face and `already_a2()` false; after =
`font=JetBrains Mono:size=9, wa Icons:size=9`; a second run leaves it alone; `--undo` restores the
original bytes, including after two whole runs. Measured against the pre-fix code in a separate worktree
at `713a1729`: the A2-pair assertion **fails there**, which is the test the brief asked for. Victor's
real `~/.config/foot/foot.ini` is verified untouched.

## A pre-existing failure, named

`scripts/test-linux-release-fetch.sh` reports **14 passed, 13 failed** on this branch AND on the base
commit `13247bdb` in a separate clean worktree - the same counts, so nothing here caused it. Its own line
explains the refusal: `candidate_names_no_commit: wa --build-info answered nothing on this bundle's binary
(a build older than the flag)`. It is not in the rows this mission touched and is left alone.

## What is NOT verified

- **The installers were not executed.** `scripts/install.sh` passes `bash -n`; `scripts/install.ps1`
  was not run (no PowerShell on this node). The Termux bundle/update suites were run.
- **No real terminal was restarted with the new font.** The evidence is the config bytes and fc-list's
  answer about coverage, not a screenshot of foot.
- **The Windows font directory and its API path** are asserted as strings, not by installing on Windows.
- **A real release bundle was not published**; the lists are asserted by the test, and the Termux suite
  proves its own path.
- **`fc-list` sees "wa Icons" only after fc-cache runs in the user's font dir**; in the scratch home it
  reported 0 because that directory is not in fontconfig's search path - the installed-file list, not
  fc-list, is what the test asserts.

## Decisions taken here, for Victor to confirm or reverse

1. Three prototype glyphs are NOT shipped (check_circle, its outline, check_bold): no row draws them, and
   "only the glyphs wa draws" is the decision.
2. The served webfonts are the .ttf files themselves rather than .woff2, so the window and the installer
   share one copy per face.
3. The default icon set is `unicode` until the setup has run, then `wa` - a set whose font is absent
   draws tofu.

## Texts to approve (operator-facing, verbatim)

1. `usage: wa setup fonts [--undo] [--dry-run] [--verbose]`
2. `  installs JetBrains Mono + wa Icons for this user and points a known terminal at them`
3. `wa setup fonts: foot -> JetBrains Mono (was Source Code Pro:size=11; backup <path>)`
4. `wa setup fonts: <terminal> left alone: no config file at <path> (a terminal nobody configured is not edited)`
5. `wa setup fonts: <terminal> left alone: cannot measure whether '<font>' draws wa's icons on this machine`
6. `wa setup fonts: <terminal> left alone: '<font>' already draws wa's icons`
7. `wa setup fonts: installed N font(s) in <dir>; no terminal config needed a change`
8. `wa setup fonts: skipped (WA_NO_FONT_SETUP is set)`
9. `wa setup fonts: refused: fonts_missing_from_bundle: <paths>`
10. `wa setup fonts: refused: fonts_source_unknown: this node cannot say where its own fonts live (WA_UI_DIR, or WASM_AGENT_LUA_ROOT for a checkout)`
11. `wa setup fonts: unknown flag: <flag>` + the usage line
12. `wa setup fonts --undo: N terminal config(s) restored, M font file(s) removed`
13. `nothing_to_undo: no record at <path>`
14. `wa setup fonts: refused: fonts_dir_unwritable: <dir>` and `fonts_copy_failed: <name>`
15. `icons_unknown_set:<value> (wa|nerd|unicode|ascii)`
16. `icons_no_such_icon:<name>`
17. `/icons [set] - which glyphs the status and footer rows draw: wa = wa Icons (glued), nerd, unicode or ascii (no argument: say which set is in force)`
18. `  icons <set>  (<source>)` and `  choose: wa (wa Icons, glued), nerd, unicode, ascii`
19. `wezterm_font_table_absent` and `terminal_kind_unknown`
