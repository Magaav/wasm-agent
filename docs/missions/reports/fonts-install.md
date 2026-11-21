# fonts-install - 'wa setup fonts' on an INSTALLED release, and a re-run that cannot hurt a backup

Mission (21/11, found by the orchestrator running release node-bfad4f8fbe59 on Victor's laptop):
`wa setup fonts` must work on an installed node, a re-run must never damage an undo, "already set up" must be
the value the command writes now, and `/health` must name the release that was just installed.

Base: `bfad4f8f` (origin/main). Branch `change/fonts-install`. Four items, one commit each (plus one follow-up on
item 1's refusal text). Nothing pushed.

## What shipped, by item

| item | commit | what it does |
|---|---|---|
| 3 | `e03e7fc4` | `M.already_a2` compares with the EXACT line this command writes now. kitty's pre-fix `symbol_map U+F0000-U+FFFFD wa Icons` and ghostty's `font-family = "wa Icons"` are no longer "already set up", and `M.edited_text` REPLACES a stale icon line in place instead of appending beside it (`M.names_icon_face`, `M.icon_line_keys`, `M.without_icon_lines`). |
| 2 | `d4c2256e` | `M.write_backup_once`: a `.wa-backup` is written once and NEVER overwritten (an existing one is kept and the row says `carried`); a fontconfig terminal is judged against what THIS run installs, not only against the record already on disk, so a first run on an already-A2 alacritty edits nothing; `M.already_a2` takes the caller's record. |
| 1 | `d72f74da` | `M.source_candidates` FINDS the bundle: WA_UI_DIR, WASM_AGENT_LUA_ROOT/ui, `<dir of this binary>/ui` (host.runtime_info), the install records the node keeps (`install-dir.txt`, `installed.txt`'s `install_dir`/`service_install_dir`), then the per-user default - each one verified to hold all three faces. Refusals name every path tried. `scripts/upgrade.sh` installs the release's `ui/fonts.css` and `ui/fonts/*` in the SAME pass as the page (one `ui_closure`, used by the copy and by all four rollback loops), refuses a release whose own `fonts.css` names faces it does not carry, and still installs a pre-fonts release. `scripts/verify-deployed.sh` verifies the faces against the commit (and only when that commit has `ui/fonts.css`); `scripts/sentinel-install-proof.mjs` reads `UI_FONT_FILES` into its exact-set rule. |
| 1 (follow-up) | `a26601c2` | a `--dry-run` refusal names the same paths a real run does (parity first: the plan must say what the run says). |
| 4 | `a1a2ec17` | `/health`'s `build` is composed PER REQUEST (`host::live_build_label`, registered by the binary with `host::set_live_build_label`) instead of the OnceLock written at boot. The node a deploy starts two seconds before `installed.txt` lands now reports the release it was told about, with no restart. |

## The four items, measured

1. **Installed node finds its fonts.** Before: the installed binary refused `fonts_source_unknown` with no
   `WA_UI_DIR`/`WASM_AGENT_LUA_ROOT`, although `ui/fonts/*.ttf` sat beside it. After (`d72f74da`, measured with a
   scratch install holding `wa` + `ui/fonts`, no env var):
   `wa setup fonts --dry-run` -> `would install 3 font(s) ... (dry run: nothing written)`, and with the faces
   removed it refuses `fonts_missing_from_bundle: .../waIcons-Regular.ttf, ... (looked at: <every path>, [<label>])`.
   The installer half is `scripts/test-upgrade-ui-fonts.sh` (8 checks): it RUNS `upgrade.sh` against a scratch
   install and release and reads the installed `ui/` back - faces in a directory that did not exist, a
   `fonts.css` without its faces refused, and a release from before `ui/fonts/` still installed.
   **What `wa serve` serves:** the on-disk UI, read per request - `rust/wa-capabilities/src/serve.rs`'s
   `ui_file(ui, path)` reads `<ui>/<name>` from the directory `--ui` names, and there is no embedded copy of
   `index.html`/`style.css`. So the stale `~/.local/share/wasm-agent/ui` `wa serve --ui` names IS what the
   window loads, and the fix is on the installer side (`UI_FILES` never listed `fonts.css` or `fonts/`), not a
   cache. On this machine the unit's own line is
   `ExecStart=%h/.local/bin/wa serve ... --ui %h/.local/share/wasm-agent/ui`, and `~/.local/share/wasm-agent/ui`
   was dated 16/11 with no `fonts/` - the measured failure, unchanged here and NOT "restored".
2. **A re-run never re-edits and never overwrites a backup.** Before (`d4c2256e`'s test, failing on base):
   the first run on an alacritty already on `JetBrains Mono` reported "alacritty -> JetBrains Mono (was JetBrains
   Mono)" and wrote already-edited bytes over `.wa-backup`. After: that run says "left alone", writes no backup,
   and a `.wa-backup` that already exists is kept byte for byte. Test: run twice, then `--undo` - the ORIGINAL
   bytes come back (verifiable `d4c2256e`).
3. **"Already A2" is the exact value written now.** Before: both stale shapes answered `true` and were never
   corrected (reproduced, then asserted as failing on base). After: `symbol_map U+F0000-U+FFFFD wa Icons` and
   `font-family = "wa Icons"` are replaced in place by `M.ICON_RANGES` / `font-codepoint-map`, exactly one icon
   line remains, and the corrected config is left alone on the next run (verifiable `e03e7fc4`).
4. **`/health` names the release just installed.** Before: a label composed once at boot from `installed.txt`,
   which `upgrade.sh` writes only after the node answers `/health` (canary: serve 10:19:13, record 10:19:15,
   health "node-7ddbfa98036a"). After (`a1a2ec17`, measured on a real scratch node): health `d72f74da+dirty`,
   then `binary_release=node-bfad4f8fbe59` written into the install dir, then health
   `node-bfad4f8fbe59` - same process, no restart - and it follows a second change.

## Tests, and where they are wired

| test | new/changed | wired in | fails on base |
|---|---|---|---|
| `scripts/test-font-setup.lua` | changed (items 1, 2, 3; 180 checks) | `scripts/test.sh` (existing row) | yes - `e03e7fc4` 11 checks, `d4c2256e` 14, `d72f74da` 5, measured against a worktree at `bfad4f8f` |
| `scripts/test-upgrade-ui-fonts.sh` | new (8 checks) | `scripts/test.sh`, beside the upgrade idle-wait row | yes - 5 of 8 fail on base |
| `scripts/test-health-build-label.sh` | new (5 checks) | `scripts/test.sh`, same block | yes - 2 of 5 fail on base |

Every new case builds its own scratch HOME/`WASM_AGENT_HOME` (`scripts/lib/scratch-home.lua`,
`scripts/lib/scratch-home.sh`), refuses the real home/store, uses its own free port and db, and kills only the
pids it started. Nothing here touches `~/.config`, `~/.local/share/fonts` or the live fleet.

## Not done, and what is still open

- **The installed `ui/` on this machine is still the 16/11 copy.** `d72f74da` fixes the installer; it does not
  (and must not) rewrite what the running node serves. The node will pick the faces up at the next deploy.
  Nothing here "restored" a file it found changed.
- **Pre-existing failures on this node**, identical on a worktree at the base commit: `scripts/test-watchdog.sh`
  (`test result: FAILED. 7 passed; 2 failed` in the crate's tests, `test-watchdog: FAILED (1 step(s))`). Not
  caused by this branch, not fixed here.
- **`scripts/install.ps1`'s `$uiNames`** already lists `fonts.css` and `fonts/*` (unchanged), and
  `scripts/package-windows.ps1`/`release-package.ps1` already package them - the Windows install path needed no
  change; the Linux `upgrade.sh` closure was the hole.
- Not pushed, per the brief.

## Texts to approve (new or changed operator-facing strings, verbatim)

1. `fonts_missing_from_bundle: <paths> (looked at: <path> [<label>], ...)`
2. `fonts_source_unknown: this node cannot say where its own fonts live (WA_UI_DIR, or WASM_AGENT_LUA_ROOT for a checkout); tried: <path> [<label>], ...`
3. `backup_failed: this command could not secure an undo at <path>`
4. `'<font>' replaced by JetBrains Mono + wa Icons (keeping the undo already at <path>)`
5. `missing release UI asset: <face> (named by the release's own fonts.css)`
6. `the faces are found from this node's own install record ...` (test-side text, listed for completeness)
