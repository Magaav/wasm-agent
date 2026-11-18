# change/codeact-fix - review of change/codeact (10 unlanded commits, base 9713a020)

Nine items, each with the fix and the test that fails on the base and passes here. Base comparison: an
isolated `git worktree add` at 9713a020 (/tmp/codeact-base) for the Lua and Rust runs, and a base
release binary built from it (base-target/release/wa) for the network test. Nothing was pushed; no other
node was built or tested on.

All work happened on avell, in /home/victor/Work/missions/codeact-fix/wt (branch change/codeact-fix),
built with CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-codeact-fix and
WA_CODEMODE_BUILD_ASSETS=/home/victor/Work/missions/codeact-fix/codemode-assets (a copy of the pinned,
verified quickjs.wasm + prelude.js this node already had - see "Not run" at the end).

## The short version

| # | item | fix | test (fails on base) |
|---|------|-----|----------------------|
| 1 | a model could read ANY vault entry through an mcp connector + probe (BLOCKER) | vault_env is operator-only; a definition carrying it is inert until an operator starts it | test-mcp-share.lua section 7 (base: the put is ACCEPTED, the probe reaches the kernel) |
| 2 | a peer's import replace:true rewrote a script an enabled connector runs | a file another registered connector runs is refused; replace needs the receiving operator | test-mcp-share.lua section 4 (base: both imports succeed) |
| 3 | wa network remove: any single admin could retire the fleet's operators | a second, different administrator must sign this exact retirement; a stored row without its proof is ignored | test-managed-network.cjs (base: one admin's retirement answers 200) |
| 4 | operations.rs cached a failed vault open forever | the slot holds a vault only when there is one | vault_cache_tests (new code) |
| 5 | a dropped image path was trusted by its extension, and any [Image #n] counted | bytes decide the type, the canonical path must stay inside an allowed root, only the tokens this draft inserted attach | host.rs image_and_token_tests (new code) |
| 6 | tests asked for: url_at, dropped_image, read_clipboard_image, mouse drag, wide-char index_at, Ctrl+X | written; Ctrl+X/Ctrl+Y are now understood from the kitty protocol too | wa-term + wa-capabilities unit tests (Ctrl+X/Ctrl+Y fails on base) |
| 7 | two URL detectors, two image-token insertions | wa-term/src/links.rs is the one detector, host.link_span serves markdown.lua; host.rs attach_image is the one insertion | test-markdown.lua (base: the link swallows its full stop) |
| 8 | Ctrl+K/U/W ignored an active selection | they act on the selection when there is one | wa-term kill_keys test (fails on base) |
| 9 | refusal.lua:261 still claimed "1 to 8 exact tool names" | the sentence no longer states a limit | refusal_codes regenerated (the contract test rejects a stale map) |

## 1. BLOCKER - a model could read any vault secret (lua/core/mcp.lua, lua/core/chat.lua)

The hole: vault_env is not a reference to a credential the *server* fetches - the kernel injects the
VALUE into whatever program the definition names, at launch (rust wa-capabilities/src/operations.rs).
vault_env is stripped from the generic operation tool and the HTTP route, but a model could `put`
{transport='stdio', program='/bin/sh', args={'-c','echo $X >/tmp/x'}, vault_env={X='<entry>'}} and then
`probe` it: mcp.control -> M.invoke -> the kernel -> the value in the child's environment. A
peer-imported definition was the same door.

The fix, in one place:

* M.names_vault(definition) and vault_gate(row, ctx, id): a row is launchable only when it names no vault
  entry, or row.vault_approved, or the caller carries ctx.operator.
* put refuses a model's definition carrying vault_env by name (mcp_vault_env_requires_operator); a peer's
  import still lands (a shared connector arrives names-only by design) but disabled and UNAPPROVED - it
  can be inspected, never launched. Even an operator's own put stores vault_approved=false.
* probe refuses before M.invoke, enable refuses before the probe-required check, and M.call refuses too
  (for a registry written before this gate). An operator's probe or on is what sets vault_approved.
* ctx.operator = true is set by exactly one caller: the /mcp command typed at the terminal
  (lua/core/chat.lua). The model's mcp tool (lua/core/tools.lua) and a peer's import
  (lua/core/federation.lua) never set it.
* M.inventory() carries vault_approved so /mcp can say which state such a connector is in.

Test: scripts/test-mcp-share.lua section 7 - the model's put is refused and nothing is launched; the
peer's import lands disabled; probe and enable are refused; the operator's probe is the approval; the
entry stays a name on the row and no value reaches the registry.
On the base tree the same test fails at the first check, and the failing run is the proof:
{"enabled":false,"id":"vault-fixture","ok":true} (the put was ACCEPTED) and
vault_entry_missing:fixture_token: store it with wa vault set fixture_token --stdin (the probe reached
the kernel and tried to inject the entry).

## 2. A peer's import replace:true (lua/core/federation.lua)

import_here now collects the scripts every OTHER registered connector runs and:

* refuses share_file_in_use (naming the connector) for any file one of them runs - not even an identical
  copy is taken over;
* refuses share_replace_requires_operator when replace is set and the caller is not the operator
  (caller.operator == true). A peer never has that, so replace is the receiving node's decision. The note
  names the operator's path: turn the connector off, remove it, share it again.

Tests (section 4 of test-mcp-share.lua): share_file_in_use for another connector's script,
share_replace_requires_operator for a peer replace, and nothing written. Base: both imports succeed (the
base answer to the replace is ok:true, files:1).

Not done, and named: files are not namespaced per connector id (the item allowed either). The
consequence: two connectors cannot share one helper script. The built-in runtime is excluded anyway, and
a share that trips this is refused by name.

## 3. wa network remove - retirement is two administrators' decision (rust/wa-rendezvous, lua/core/nodes.lua, lua/core/init.lua)

The hole: POST /operators with remove + retire: true retired an environment operator on the word of ANY
administrator; the fleet-roster revocation gate lived only in M.network_remove on the asking node, and
`remaining` counted the caller as a survivor, so one administrator could empty the fleet's own operator
list down to itself.

Now (approval_problem):

* the caller signs the request and a DIFFERENT administrator signs this exact retirement:
  retire|<target>|<caller>|<nonce>|<ts>, verified with the approver's registered key inside a 900 s
  window, the approval's node/ts/signature travelling in the request body;
* a caller that is NOT one of the environment's operators also needs an environment operator's
  signature, so a key the registry added at runtime (a vouch, never the root of trust) cannot shorten
  that list;
* last_operator_problem no longer counts a caller that is outside the list - an added administrator can
  never be the last one standing;
* the stored row keeps the approval and load_runtime_operators re-verifies it (stored_retirement_holds):
  a row without a valid signature - written by hand, or from before this change - retires nobody. Two
  columns are added to retired_operators (ignored when already present).

Client: M.network_approve_retire(target, caller, nonce) signs the message on the second administrator's
node (wa network approve <id> --for <caller> --nonce <n>), and wa network remove <id> --nonce <n>
--approval '<json>' sends it. Without an approval the refusal carries the nonce and the exact command to
run elsewhere. docs/RENDEZVOUS.md says all of it.

Tests: scripts/test-managed-network.cjs - no approval -> approval_required; self ->
operator_cannot_retire_itself; a caller approving itself -> approval_self; a customer's signature ->
approval_not_an_administrator; an approval signed for another nonce -> approval_bad_signature; a third
administrator's signature retires it; the service vouches for what is left; the retirement and the list
survive a restart; a runtime administrator's "retire everyone" sweep is refused at each step. 55 checks,
0 skips. Base binary: fails at "a retirement without a second administrator's signature is refused", and
the recorded base answer is {"status":200,"ok":true,"operators":[<two ids>]} - one administrator retired
another operator alone.
The pure rules also have unit tests (retirement_tests): the message shape, the caller/remaining rule, the
added-administrator rule, and a stored row with no verifiable proof.

Residual, named: a compromised ENVIRONMENT operator plus one accomplice administrator can still reduce the
list to itself (each step is then signed by two administrators). The fleet key is the answer to that, and
the roster still decides on the asking node; the server-side gate now needs two keys, not one.

## 4. A failed vault open was cached forever (rust/wa-capabilities/src/operations.rs)

OnceLock<Option<VaultService>> remembered the first None, so a node whose vault could not open once
answered vault_unavailable for the rest of the process. Replaced by Mutex<Option<VaultService>> +
ensure_cached (a failure is retried on the next launch, a success is not re-opened) and vault_value,
which keeps the same two sentences a caller already knows. Unit tests vault_cache_tests: the second call
opens after a first failure, and an open vault is never re-opened.

## 5. Dropped / pasted image paths (rust/wa-capabilities/src/host.rs)

* sniff_image - PNG/JPEG/WebP/GIF from the bytes. The extension is a name, not evidence: a .png that is a
  shell script is refused.
* attachment_path - the path is canonicalized first and must sit inside an allowed root (the node's home,
  HOME, the working directory, the temporary directory). A symlink is refused by where it LANDS, which is
  the case that mattered (a link that reads a private file and attaches it to a message).
* Clipboard payloads go through the same sniff, so a clipboard that says image/png and is not one is
  refused instead of attached; ClipboardHost + read_clipboard_image_with make the reader testable without
  a clipboard (off switch, no tools, a Wayland that answers, a lie about its type).
* [Image #n] counts only if this draft inserted it: attach_image records the token in draft_images,
  Action::Submit keeps the ones still in the submitted line, and host.input_image answers only for those.
  A token typed by hand, or left over from an earlier message, attaches nothing.
* Named behaviour change: a dropped path from OUTSIDE the allowed roots is now refused (the item asked,
  minimally, for symlinks out of them; this is the strict form and it is documented).

Tests image_and_token_tests (10): the bytes decide the type; a real image in an allowed directory (plain,
quoted and file://); a non-image named .png; empty/absent/multiline paths; a symlink out of the roots
refused and one inside them accepted; the clipboard off / absent / Wayland cases and a clipboard that
lies; the token filter; one token number minted per attachment.

## 6. The tests the review asked for

| asked | where |
|-------|-------|
| url_at | rust/wa-term/src/links.rs - a URL in a sentence, in brackets, two in a line, a bare scheme, punctuation, byte offsets, wide characters |
| dropped_image | host.rs image_and_token_tests |
| read_clipboard_image | host.rs - off, absent, Wayland, a lying clipboard, an unknown type |
| mouse-drag selection | wa-term - press then drag selects, a backwards drag, an empty drag selects nothing |
| wide-char index_at | wa-term - both cells of a wide character, the end of the draft, outside the box |
| Ctrl+X mapping | wa-term - byte 24 redoes, kitty's ESC[120;5u redoes (it was swallowed before), Ctrl+Y too |

## 7. One implementation (rust/wa-term/src/links.rs, rust/wa-capabilities/src/host.rs, lua/core/markdown.lua, docs/HOST.md)

* The URL detector lives in wa_term::links (spans, first, first_bytes, char_at_cell, at). host.rs's click
  path calls links::at; markdown.lua no longer has a URL pattern at all - it asks host.link_span(rest)
  (a new capability, documented in docs/HOST.md) for the first link and styles exactly those bytes. The
  two used to disagree: the pattern kept a trailing dot and stopped at a plus sign.
* One image-token insertion: attach_image in host.rs is used by both Action::Pasted (a dropped path) and
  Action::PasteImage (Ctrl+V).

Test: scripts/test-markdown.lua - the underlined run is exactly the two URLs, without the full stop or the
bracket. Base: https://example.invalid/x.https://example.invalid/y (the links swallowed the punctuation),
1 failed of 77.

## 8. Ctrl+K / Ctrl+U / Ctrl+W with a selection (rust/wa-term/src/terminal_editor.rs)

All three delete the selection first (delete_selection) and only fall back to their line/word behaviour
with no selection. Test kill_keys_act_on_the_selection_when_there_is_one: for each key the selection goes,
the rest of the line stays, the cursor lands where the selection began, and one undo brings it back; a
backwards selection behaves the same; with no selection the three kills are unchanged. Base: "Ctrl+K
removes the selection, not the rest of the line" fails.

## 9. refusal.lua:261 (the only text change)

invalid_tool_search_names's fix line said "1 to 8 exact tool names" although the batch cap was removed (a
named batch is never truncated by limit). It now says "a list of exact tool names, as many as the script
needs". lua/core/refusal_codes.lua was regenerated (lua5.4 scripts/gen-refusal-codes.lua --write) because
scripts/test-refusal-contract.lua refuses a stale map - the regeneration is mechanical and adds the codes
the other items introduced (mcp_vault_env_requires_operator, approval_*, ...).
Left alone on purpose: the neighbouring invalid_tool_search_limit fix still says "between 1 and 8 for a
batch of names", which is also stale. That is outside the one line this item allows; flagged here.

## What was run, and what it answered

On this tree (new code):

* cargo test -p wa-term --lib: 147 passed (137 were there before)
* cargo test -p wa-rendezvous --lib: 13 passed (4 new retirement tests)
* cargo test -p wa-capabilities --lib: 299 passed (10 image/token, 2 vault-cache new; the inventory drift
  test also needed three PRE-EXISTING undocumented capabilities - input_image, transcript_copy_first,
  transcript_expand - plus link_span, all now in docs/HOST.md)
* scripts/test-mcp-share.lua: 39 checks ok
* scripts/test-markdown.lua: 102 checks ok
* node scripts/test-managed-network.cjs <new binary>: 55 checks, 0 skips
* other suites touched by these files, all ok: test-mcp-command (132), test-mcp-registry-state (24),
  test-mcp-retired-connector (17), test-capability-inventory (135 capabilities, 425 checks),
  test-federation (48), test-cli-view (369), test-refusal-contract (15429), test-tool-search-names (49),
  test-envelope (131).

Against the base (the "fails before" half):

* test-mcp-share.lua with the base lua/ tree: 12 failed of 39 (the vault_env and the import blocks)
* test-markdown.lua with the base lua/ tree: 1 failed of 77 (the link swallowed the full stop)
* the new editor tests appended to the base wa-term: 2 failed (kill_keys_act_on_the_selection, kitty's
  Ctrl+Y); the wide-char and drag tests pass on base - they are coverage the review asked for, not a
  behaviour change
* node test-managed-network.cjs with the base binary: fails at the approval check; the base answers
  {"status":200,"ok":true,...} to a retirement with no second signature.

## Pre-existing failures on this node (not mine - same result with the base lua tree)

* scripts/test-nodes-cli.lua: 3 of 12 ("the list is a panel of nodes", "an unbound node says it has no
  cluster...", "an unbound node suggests no fabric").
* scripts/test-hotreload.lua: 5 of 215, all release_unsigned_or_forged: ... signed by
  release-signing-<id>, which this node does not trust. This node's release-key trust file is not the one
  the test signs with.

## Not run, and why

* verify/b1-test.sh (the whole gate): it unsets every WA_*/WASM_AGENT_* variable and then builds, so it
  cannot see WA_CODEMODE_BUILD_ASSETS, and rust/wa-capabilities/build.rs refuses a release build without
  code-mode assets. The base tree's gate attempt failed exactly there (code-mode assets required,
  /home/victor/Work/missions/codeact-fix/logs/gate.log). The assets ARE prepared on this node (the pinned
  quickjs.wasm/prelude.js with matching sha256), which is what every build and test above used; the gate
  script's own environment fence is what a full gate run would need changed - not something to change
  silently from a review branch.
* The Windows/PowerShell half of test-managed-network.cjs (it needs a release archive argument); the
  isolated registry/guest half is the run reported above.

## Not verified, said plainly

* items 4, 5 and 7's Rust halves are covered by unit tests of NEW functions; the base has no such function
  to fail on. Where a behaviour is observable from outside, the Lua/.cjs test above shows the before and
  after; where it is not (a cached vault failure, an extension trusted over bytes), the evidence is the
  code citation plus the test of the rule.
* nothing was pushed, no branch was merged, no other node was built or tested on.

# Round 2 - Victor's decisions (18/11) and /keybindings

Same worktree and branch (change/codeact-fix), base origin/change/codeact @ 9713a020. Built and tested
on avell only; nothing was pushed. Commit faaf1d0b.

## 0. The decisions, recorded (not re-argued)

Approved as they are, and left exactly as they are: the FIRST_GUIDANCE fence clause, the "Use full
paths, as given (programs and files); never ~." guidance line, tool_search names without the 8 limit,
the unknown_mcp_connector refusal, and the mcp summary note. Ctrl+X = REDO is by design: nothing was
remapped, the existing test still asserts it, and the new table says so in the row itself ("redo as
well - by design (operator 18/11); Ctrl+Y does the same, and a test asserts it"), so a reader of
/keybindings learns the reason with the key.

## 1. /keybindings - one table, and the dispatchers read it

**The problem.** The console's keys were decided in five places and listed nowhere:
`terminal_editor::Editor::feed_key` (a match over control bytes and escape sequences), its
`menu_key`, `transcript::NavDecoder`, `terminal_editor::Panel::feed`, and the pointer routing in
`rust/wa-capabilities/src/host.rs`. Nothing anywhere said what Ctrl+X does. A list written by hand
beside five dispatchers is wrong the first time one of them changes.

**The fix.** `rust/wa-term/src/keymap.rs` is the table: one row per binding - the surface it applies
in (Draft, Menu, Transcript, Fullscreen, Panel, Mouse, Console), its group inside that surface, the key
as a reader says it, the trigger the dispatcher matches (bytes, a pointer gesture, or the "any other
character" fall-through), the act, and one sentence of what it does. The acts are enums
(`DraftAct`, `MenuAct`, `NavAct`, `PanelAct`, `Gesture`, `HostAct`) whose consumers match them
exhaustively, so a row cannot name behaviour that does not exist and a behaviour cannot be reached by a
key that has no row.

Each dispatcher now reads it:

| dispatcher | reads |
|---|---|
| `Editor::feed` / `perform` | `draft_byte`, `draft_seq`, `draft_prefix` - one code path per act |
| `Editor::menu_key` | `menu_seq`, `menu_byte` |
| `transcript::NavDecoder` | `nav_seq`, `nav_byte` |
| `Panel::feed` / `perform` | `panel_seq`, `panel_byte`, `panel_digit`, `panel_letter` |
| the reader thread's pointer routing (`handle_mouse`) | `gestures(pose)` - the order a press is tried in is the table's (a link claims a press before a selection does) |
| the reader thread's own keys (Ctrl+O, Ctrl+C on a transcript selection, the lone Esc) | `console_byte`, `console_escape` |
| the fullscreen console | generated from the settings it obeys (`WA_TUI_KEYS`), not copied from the defaults |

The draft's decoder changed shape with it: an exact row performs its act, a prefix of a row waits for
the rest, and anything else is swallowed to its final byte - so an unknown escape sequence still never
reaches the prompt, and "is this a key?" is answered by the table rather than by a chain of `if seq ==`.

**What the list contains** (all of it in `keymap.rs`, 110 rows): Enter, Ctrl+J/Shift+Enter (five
terminal spellings), Esc and Esc twice, Ctrl+C (copy the selection / interrupt / leave bash mode /
quit), Ctrl+Insert, Backspace and DEL, Delete, Ctrl+D, Ctrl+K/U/W (selection first), Ctrl+A,
Shift+arrows, Shift+Home/End, arrows, Home/End, Ctrl+Home/End, Ctrl+E, Ctrl+P/N, Ctrl+Z/Ctrl+Y/Ctrl+X
and their kitty forms, Ctrl+Shift+Z, Ctrl+V and kitty's, the two paste markers, Ctrl+Up, PageUp/PageDown,
Ctrl+PageDown, the slash menu's Up/Down/Tab/Enter, the transcript's blocks (arrows, Ctrl+O, PageUp/Down,
Ctrl+PageDown, Enter/Ctrl+C, Esc), a panel page (Up/Down, 1-9, a page's own letters, Enter, Esc, Left,
Backspace, Ctrl+U), the pointer (bar press, draft press, expand toggle, link copy, block copy,
transcript selection, drag, release, wheel, hover), and the console's three.

**How /keybindings is printed.** One capability, one formatter, three surfaces:
`host.keybindings()` (`rust/wa-capabilities/src/host.rs`) answers `keymap::json()`;
`lua/core/keybindings.lua` lays the rows out (a key column, a sentence wrapped under it - never cut at
the screen's edge) and names no key itself; `lua/core/chat.lua` has the REPL arm (balloon pages),
`lua/core/local_views.lua` publishes the same pages mid-run, and `wa_keybindings()` in
`lua/core/server.lua` plus a `/keybindings` route in `serve.rs` give the window the same text. `/help`
names it three times: the registry row, the row's own hint, and a closing line in the help text
("the keys: /keybindings lists every special key, what it does and where it applies").

## 2. The window's own keys

The window had its own five places: a `keydown` on the composer, one on the document, one on the
shell's field, one inside each scrollable panel, and the command list's arrows. They now read one table
too: `WINDOW_KEYS` and `windowKey(event)` in `ui/app.js` (12 rows: Enter, Ctrl/Cmd+Enter, Ctrl+Z,
Ctrl+Shift+Z/Ctrl+Y, arrows, Tab, the page keys, Esc, Ctrl+backtick, Ctrl+E, Ctrl+D), and the handlers
switch on the ids it answers. `/keybindings` in the window shows both halves: the node's console rows
(the route above) and this window's table, generated by `windowKeyList()`.

## 3. Tests, and what each proves

| test | what it proves |
|---|---|
| `keymap::every_act_has_a_row` | an act with no row is a key nobody can look up (all six surfaces) |
| `keymap::every_row_is_dispatched` | a row with no dispatch is a list that lies: every row is looked up by its surface's own dispatcher function |
| `keymap::no_key_has_two_acts_in_the_same_surface` | a second row for one key would be unreachable |
| `terminal_editor::no_key_outside_the_table_does_anything` | the other direction: every control byte with no row leaves the draft untouched, every other character types |
| `terminal_editor::an_escape_sequence_nobody_binds_is_swallowed` | five unbindable sequences leave nothing in the draft |
| `keymap::the_list_is_the_table` | the rendered rows are the table's rows, in order, plus the live fullscreen ones |
| `keymap::the_fullscreen_rows_follow_the_operators_keys` | `WA_TUI_KEYS=pageup=none,ctrl+u=line-up` changes the list, and the unbound actions are listed with the knob |
| `keymap::the_json_carries_every_row` | the capability's answer carries every surface and every sentence |
| `scripts/test-keybindings.lua` (53 checks) | the rows come from the capability and not from Lua (the module is asserted to name no key at all), the column aligns, a long sentence wraps, /help names it, the registry row, the REPL arm, the mid-run view and the node's handler exist; and, with the real binary, the rows carry Ctrl+X-as-redo, Home/End, Ctrl+Home/End, Ctrl+A, Shift+arrows, the three kills, Ctrl+V's image, Ctrl+C/Ctrl+Insert, the drag, Ctrl+O and Esc |
| `tests/composer-input.js` (100 checks) | the window's table: every key answers its row's id, a key the table does not name answers "", every id is used by a handler, the list prints the table, and Esc closes the shell through windowKey -> the document's handler |
| `scripts/test-command-parity.cjs` | the CLI and the window offer the same commands (now including /keybindings), and the REPL has an arm for each |
| `scripts/test-serve-concurrency.sh` (added check) | the `/keybindings` route answers 200 with the console's rows - the same regression the `/efficiency` check was added for |

The editor's existing behaviour is unchanged: 147 of the 157 wa-term tests are the ones that were
there before (including Ctrl+X redoing, Ctrl+K/U/W on a selection, mouse drag, wide characters), and
they pass against the new dispatchers.

## 4. What was run

On this tree, today:

* `cargo test -p wa-term --lib`: 157 passed (147 before this round: +8 keymap, +2 editor).
* `cargo test -p wa-capabilities --lib`: 299 passed.
* `cargo check --workspace --all-targets`: EXIT=0 (so nothing else in the workspace broke).
* Through the built binary (`WA_SCRIPT=...`, `WASM_AGENT_LUA_ROOT=<this tree>`):
  test-keybindings 53, test-cli-view 369, test-cli-balloon 75, test-nodes-instant 26,
  test-mcp-command 132, test-capability-inventory 428 checks / 136 capabilities, test-command-parity 62.
* `node --test tests/composer-input.js`: 100 ok.
* **End to end, the CLI**: `/keybindings` typed into a real `wa chat` on a pty (dev tree) prints
  "Keys (1/15)", the surface headings ("Text area (the draft)", "Sending", "Running a turn", ...) and
  one row per key with the sentence wrapped under its column.
* **End to end, the node**: the handler `wa_keybindings()` in a real interpreter answers 110 rows /
  204 text lines; the route over HTTP (`wa serve`, then `curl /keybindings`) answers 200 with 28 430
  bytes, carrying "Ctrl+X", "redo as well", "Ctrl+Home" and "WA_TUI_KEYS".

**The base has none of this** - the table, the capability, the command and the route do not exist at
9713a020 - so the "fails before" half of every test above is an absence rather than a wrong answer.
The half that could have been wrong instead (a key the dispatcher handles that the table omits, or one
the table lists that nothing dispatches) is what the four Rust tests above are for, and they are the
reason the list cannot drift.

## 5. Pre-existing failures on this node (not this branch)

* `scripts/test-nodes-cli.lua`: 3 of 12 ("the list is a panel of nodes", "an unbound node says it has no
  cluster...", "an unbound node suggests no fabric") - identical before this round.
* `scripts/test-hotreload.lua`: 6 of 217, every one of them the fixture payload's release signature
  (`release_unsigned_or_forged: ... is signed by release-signing-<id>, which this node does not
  trust`). Round 1 measured 5 of 215 on the same class. The counts moved because this branch adds one
  module to the reloadable UI list and that scenario iterates those modules; none of the six failures
  names a keybindings file, and the class is the node's trust file, which no change here touches.
* A binary built WITHOUT `WA_CODEMODE_BUILD_ASSETS` cannot run `test-capability-inventory` or anything
  else that needs the code-mode sandbox: `the sandbox answered capabilities()` fails through
  `rust/wa-capabilities/build.rs`'s "debug builds may embed nothing" path. With the pinned assets this
  node has, the suite is 428 checks, ok. Every number above comes from a binary built with them.

## 6. Not verified, and why

* `scripts/test-serve-concurrency.sh`: I added the `/keybindings` check to it and tried to run it here;
  the fixture's server did not answer `/health` (its log is retained, no product error in it), so that
  script's new check has not been exercised by the script itself. The route was verified directly
  instead (section 4).
* The window's `/keybindings` in a real browser or the WebView companion: not run (no browser here).
  Its two halves were verified separately - the node's route over HTTP, and the window's table through
  the stub-DOM harness that loads `ui/app.js`.
* The Windows/Cmd spellings of the window's keys: same code path, not exercised on this node.
* No other node was built, tested or synced on; nothing was pushed or merged.

## 7. Residual, named

* The pointer's *order* is the table's, but the geometry inside each gesture is still the host's: a
  press that is on no link, bar or box is a selection. The table says what the pointer does, not where;
  making that data would be a second table pretending to describe layout.
* A panel's lone Esc is dispatched by the console's Esc row and reaches `Panel::escape` directly; the
  Panel surface's own row is Esc twice (`\x1b\x1b`), which the panel's decoder dispatches. Two rows,
  one act, and the row says so.
* The fullscreen rows are generated from `Settings::from_env` at the moment the capability is called,
  so an operator's `WA_TUI_KEYS` is reflected; a *change* to the env file needs a new process, exactly
  as the console itself does.
* The list is long (110 rows, ~204 lines, 15 pages at 80x24). That is the complete list the mission
  asked for; the grouping by surface is what keeps it navigable.

# Round 3 - the security verification of ac95a73d

Seven items from the review of round 1, each fixed with an adversarial test and each proven against the
base tree. The verbatim list of every model-visible refusal/note string of all three rounds is the last
section (`Every model-visible string, rounds 1-3`), for Victor's approval.

## 1. HIGH - the vault approval was a writable boolean, and the scripts it covers are writable too

**The hole.** `vault_approved` lived as one boolean in `memory.db` (`lua/core/mcp.lua`), which the
model's own `bash`/`write`/... could reach: `secret_guard.ROOTS` did not name `memory.db`, and
`path_guard` only refuses recursive deletes. So `sqlite3 ~/.wasm-agent/memory.db "update meta set
value=..."` turned an unapproved connector into an approved one, and `mcp.lua` :164 (now
`vault_gate`) then let the probe launch it. The second half is worse and independent of the database:
an already-approved connector's program lives in a script directory the agent can write
(`<data>/scripts`, `~/.local/bin/scripts`), so the approval could be kept and the CODE replaced.

**The fix, two halves.**

(a) An approval now records WHAT it approves. When the operator's own probe/on approves a vault
connector, the row keeps a manifest (`M.vault_manifest`, `lua/core/mcp.lua`) and its SHA-256 over:
the program, its arguments in order, **every script file the connector runs** (this node's MCP runtime
in the script directory, plus each `.mjs`/`.js`/`.cjs`/`.lua`/`.sh`/`.bash`/`.py`/`.rb`/`.pl`/`.ps1`/
`.bat` the definition names, each with the hash of its bytes NOW) and the vault environment names it
asks for. Two places check it:

* the console gate recomputes it before a call or an enable and refuses `mcp_vault_approval_stale`
  (a script or an argument changed since the operator approved it) or `mcp_vault_approval_missing`
  (an approval recorded before digests existed);
* `rust/wa-capabilities/src/operations.rs` recomputes it from the bytes on disk immediately BEFORE it
  reads a value, and refuses `vault_approval_required`, `vault_approval_unreadable:<path>`,
  `vault_approval_script_not_covered:<path>` or `vault_approval_mismatch`. Nothing is launched and no
  value is read. It also refuses a launch whose own command line runs a script the approval does not
  name (`script_not_covered`), which is what ties the digest to the process being started.

One canonical text, two implementations (`M.vault_approval_text` / `approval_text`), and each side's
test pins the SAME fixture digest
(`0423d0cb712e6441592ef2a8d04f8179ba03d7d797bfb233b3f07939ae450da8`), so neither escaping rule can
drift. Every field is percent-escaped, so a newline or a space inside an argument cannot forge a line.

(b) `lua/core/secret_guard.lua` refuses `memory.db` (and its `-wal`/`-shm`) and the connector script
directories - `<data>/scripts`, `~/.local/bin/scripts`, `wasm-agent-sandbox/scripts`, plus whatever
`WA_MCP_SCRIPT_DIR` / `WA_INSTALL_DIR` / `WASM_AGENT_LUA_ROOT` resolve at load - for `read`/`write`/
`edit`/`ls`/`grep` and for a `bash` that names them (`secret_path_denied`, 403).

**Tests.** `scripts/test-mcp-vault-approval.lua` (new, 29 checks): the cross-language digest pin, the
field escaping, the manifest covering the runtime and the connector script, the operator's "on"
recording the digest, the launch carrying it to the kernel, then the attack - the script rewritten after
the approval is refused `mcp_vault_approval_stale` with `tool_call_issued: false`, no process started,
both digests named in the answer, and the approved bytes restoring the approval; an approval with no
digest answers `mcp_vault_approval_missing`; a model's put carrying `vault_env` is still refused.
`operations.rs` `vault_approval_tests` (5) prove the kernel side: an approved launch accepted, a rewritten
script and changed arguments refused, a launch running an uncovered script refused, a missing
approval/missing script refused by name, and the script-path test. `scripts/test-secret-guard.lua`
grew the memory.db and script-directory refusals (10 more checks, and the three that assert an
ordinary temp file and the node's own state root are still reachable as before).

**Base.** `/tmp/base-probe.lua` on the stashed tree: `memory_db_write: ALLOWED`,
`scripts_write: ALLOWED`, `vault_manifest: ABSENT`. The new test does not even load on base.

**Named, in the docs (docs/VAULT.md, docs/MCP.md):** the agent runs as the node's uid, so a
deliberately obfuscated shell write can still reach `memory.db` and an approval row can still be FORGED
with a matching digest - the digest cannot tell a forged approval from a real one, because both are rows
in a store the agent can reach. The complete fix is an operator-SIGNED approval verified against a key
that does not live in the store under check (the separate-uid vault): a follow-up, not claimed here.

## 2. MEDIUM - an empty file list skipped the replace check (lua/core/federation.lua)

`share_replace_requires_operator` was checked INSIDE the per-file loop, so `files: []` with
`replace: true` skipped it and reached the connector-id branch: the peer overwrote this node's
definition of a connector - one that may be enabled - with no file to inspect and nobody's approval.
The check now runs before the loop, whatever the file list holds, and its sentence says it covers a
definition as well as a script.

**Test.** `scripts/test-mcp-share.lua`: a replace with no files is refused for an existing id (and the
definition this node had keeps its name) and for a new id (nothing is registered). Base:
`replace_with_no_files: ACCEPTED, definition replaced`, `name_after: "TAKEN OVER"`; branch:
`share_replace_requires_operator`, `name_after: "T"`. The three name/checksum/built-in assertions that
used `replace = true` now ask their question without it, and one new assertion pins that a peer replace
is refused before the built-in rule is even reached (39 -> 44 checks).

## 3. MEDIUM - a stored retirement was verified against a key from its own database (rust/wa-rendezvous)

`stored_retirement_holds` did not check that the approver is in `WASM_AGENT_NETWORK_ADMINS`, did not
check the approval's window, and took the approver's public key from `public_key_of` - the same SQLite
database the row lives in. Anyone able to write the registry could retire an environment operator by
inserting their own key under an administrator's id and signing.

Now (`stored_retirement_holds(target, retired_by, approver, approval, retired_at, environment, keys)`):
the approver must be one of the ENVIRONMENT's administrators, its key must be the one the environment
names for it - new `WASM_AGENT_NETWORK_ADMIN_KEYS`, `<node-id>=<hex public key>` pairs, comma-separated -
and the approval must be contemporary with the retirement it approved (inside `APPROVAL_WINDOW_SECONDS`
of the row's own `retired_at`, the same 900 s window `approval_problem` enforces when the retirement is
made). With the key list unset, no stored approval can be verified and no retirement is applied - the
safe direction, and the log says so once at start.

**Tests** (`retirement_tests`, 4 tests / 15 in the crate): a valid second signature is applied; no
approval, a bad signature and a row moved to another caller are not; **an approver the environment does
not name retires nobody whatever the database says** (the right key with a valid signature, the
approver absent from `WASM_AGENT_NETWORK_ADMINS`; then the same signature with the environment naming no
key, and with a different key under the same id); and an approval outside the window is not applied in
either direction. Real Ed25519 keys are generated in the test, so a signature is the only thing that can
make a row count.

Docs: `docs/RENDEZVOUS.md` (the rule and the upgrade note), `deploy/wa-rendezvous.service` (the
variable, beside the admin list).

## 4. LOW - the vault cache test tested a helper the launch path did not call

`vault_value` had its own copy of the retry rule, so `vault_cache_tests` proved the rule about a
function nothing called. `vault_value` now opens the slot through `ensure_cached` (through
`vault_value_with`, which takes the opener and the read as parameters), and
`the_launch_path_opens_the_vault_through_the_one_retry_rule` runs THE launch path: a failed open is
retried on the next launch, an open vault is reused and never reopened.

## 5. LOW - image_roots was all of HOME (rust/wa-capabilities/src/host.rs)

`image_roots` was `WASM_AGENT_HOME`/`HOME`, the working directory and the machine's temp directory - every
file the user owns, reachable by dropping a path into the composer. It is now the session's own folder
(where the run was started), the node's state root (scratch, tool-results) and ONE explicit drop
directory: `WA_IMAGE_DROP_DIR`, else `<state>/attachments`. `image_drop_dir_with` is the tested seam.

**Tests** (`image_and_token_tests`): a path in an allowed directory is read (quoted and `file://` too), a
file whose bytes are not an image is refused, a symlink is refused by where it lands, and the new
`the_allowed_directories_are_the_sessions_folders_and_one_drop_dir` asserts the drop dir is a root while
all of HOME and the machine's temp directory are NOT; `the_drop_directory_is_configurable_and_defaults_under_the_state_root`
pins the knob. The tests pass their own directory in (`dropped_image_in`), so nothing writes into the
node's state.

## 6. The update banner: one definition, and its two commands in bold

`update_banner.M.LINE` is now the sentence Victor approved (18/11), and `M.COMMANDS` is the list of
words in it that are rendered bold:

    Update available (<sha>) \u2014 /update here, or wa update in a terminal

with **/update** and **wa update** in bold, on the same warning-yellow line. `M.line(sha)` is the one
place the `%s` is filled. The comments that used to restate a different sentence now point at the
module: `lua/core/chat.lua`, `lua/core/cli_view.lua` (two), `lua/core/server.lua`. The renderers read the
list rather than keeping their own: `cli_view.M.emphasise` for the CLI's row, and
`wa_term::terminal_editor::Editor::session_content` for the native row (which bolded only `wa update`
before). The docs that quoted the old sentence were updated with it (RELEASE-UPDATE.md, TOOL-PROGRESS.md,
COMPONENTS.md).

**Tests:** `scripts/test-update-banner.lua` 227 checks (the sentence, and the drawn row now expects the
emphasised line: `notice_drawn()`); `scripts/test-cli-view.lua` adds the drawn row with both bold
spans, the transcript staying plain, and a plain notice (no command list) unchanged;
`wa-term`'s editor test asserts both words are bold and nothing else is.

TODO hook: deploy-ancestry pins are not on this branch, so the pinned sentence
(`Pinned to <build> (<reason>) - update held; /update --unpin to release`) is not added. When pins land,
it belongs beside `M.LINE` in the same module and its `COMMANDS`-style list carries `/update --unpin`.

## 7. The run status bar keeps Δ and gets ↑ back

Victor: "only delta is not enough". `METHODS:run_numbers` now reads
`👣steps·step-time Δadded ↑input-total ↓output ◷run-time` - Δ (what the run added to the context,
from 727a99eb) kept, and ↑ (the SESSION's input-token total, the number the footer prints as Σ↑) right
after it: `Δ12.3k ↑4.6M ↓310`. The per-turn footer line (`M.footer`) already had its ↑ (the run's own
prompt) and is unchanged.

**Tests:** `scripts/test-cli-view.lua` - `METHODS:run_numbers` exactly (`Δ12.3k ↑4.6M ↓310`), a first
step that says Δ0 and the total it sent, and the two RENDERED status lines through the editor path now
expect `Δ27.2k ↑120.4k ↓1.0k` and `Δ2.8k ↑150.4k ↓450`.

## Also in this commit, and not one of the seven

`docs/ENVELOPE.md`'s generated tool-catalogue block, regenerated with the built binary. The pre-commit
hook refused the commit ("stale generated blocks ... docs/ENVELOPE.md: tool-catalogue") and the block was
ALREADY stale at HEAD: the same check over the stashed tree with the node's installed binary reports the
same line. The whole diff is one row - `recall`'s parameters are `limit? query? scope?`, not
`query limit? scope?`. It is here because the guard refuses a stale block; no rule was bypassed.

## Every model-visible string, rounds 1-3 (for Victor's approval)

Everything here is text a MODEL reads (a tool answer, a `note` field, a refusal). Operator-only and
user-only strings are in their own two lists at the end, because they never reach a model. Strings the
round did not change are marked "unchanged" and are repeated for approval all the same; a string round 3
replaced is shown as it is NOW with the old wording named.

### Round 1 (commit ac95a73d) - the vault gate and the share half

1. Refusal code `mcp_vault_env_requires_operator` (unchanged in 3) with

       this connector names a vault entry (vault_env), so only the operator can start it: /mcp <id> probe (or on) at the operator's own terminal. Nothing was launched.

2. The `put` answer's note when the definition names a vault entry (unchanged in 3):

       names a vault entry: inert until the operator approves it (/mcp <id> probe, then on)

3. Refusal code `share_file_in_use` (unchanged in 3) with `name`, `connector` and

       a registered connector (<connector id>) runs that script: this node replaces it only by the operator's own hand - turn that connector off and remove it (/mcp <connector id> off), or share under another file name

4. Refusal code `share_replace_requires_operator` - **sentence CHANGED in round 3** (the check moved out
   of the loop, and it now covers a definition as well as a script). Round 1-2 wording:

       replace overwrites a script this node already has, so it is a decision for the operator here: remove the connector (/mcp <id> off, then remove) and let it be shared again

   Round 3 (now):

       replace overwrites what this node already has (a definition, or a script it runs), so it is a decision for the operator here: remove the connector (/mcp <id> off, then remove) and let it be shared again, or share it under another id

5. Refusal codes with no note of their own (unchanged in 3): `share_definition_missing`,
   `share_too_many_files`, `share_file_name_invalid`, `share_file_is_built_in`, `share_file_unverified`,
   `share_file_not_written`, `share_file_unreadable`, `mcp_script_directory_unbound`.

6. Notes (unchanged in 3), each with the code above it:

       share_file_exists_differs: share again with replace to overwrite it
       share_connector_exists:   share again with replace to overwrite it

7. The successful import's note (unchanged in 3; the parenthesised half appears only when the definition
   names vault entries):

       registered disabled. On that node: wa vault set <entry> / <entry> --stdin, then /mcp <id> probe, then /mcp <id> on.

8. `mcp_vault_env_requires_stdio` and `invalid_mcp_vault_env` (unchanged in 3): the codes `validate`
   answers for a vault reference on a non-stdio transport or with a malformed name.

9. The model's `mcp` list note (unchanged in 3):

       One row per connector. Tool schemas: searchTools("select:<names>"); a connector's full row: mcp({action:"list",id}).

10. Round 1's other text change, `invalid_tool_search_names`'s fix line (unchanged in 3):

        send `{names:["read","bash"]}` - a list of exact tool names, as many as the script needs.

### Round 2 (commit faaf1d0b) - /keybindings

No new or changed model-visible refusal or note string: round 2 recorded Victor's decisions about texts
that already existed (the FIRST_GUIDANCE fence clause, the "Use full paths, as given (programs and
files); never ~." line, the tool_search names limit, the `unknown_mcp_connector` refusal, the mcp summary
note above) and added a capability, a view and a route. The only edits to text a model reads were
mechanical (the regenerated `refusal_codes` map).

### Round 3 - the approval digest, both sides

11. Refusal code `mcp_vault_approval_missing` (new) with `id`, `outcome: "not_submitted"`,
    `tool_call_issued: false` and

        this connector's approval predates the digest that says what it covers, so nothing was launched and no value was read. Approve it again at the operator's own terminal: /mcp <id> probe, then /mcp <id> on.

12. Refusal code `mcp_vault_approval_stale` (new) with `id`, `outcome: "not_submitted"`,
    `tool_call_issued: false`, `approved: <hex>`, `now: <hex>` and

        this connector's program, arguments or scripts changed after the operator approved it, so nothing was launched and no value was read. Approve it again at the operator's own terminal: /mcp <id> probe, then /mcp <id> on.

13. The kernel's refusals (new; `rust/wa-capabilities/src/operations.rs`, the answer of the launch):

        vault_approval_required: this connector names a vault entry but carries no approval digest, so no value was read and nothing was launched. A vault connector is approved at the operator's own terminal: /mcp <id> probe, then /mcp <id> on

        vault_approval_required: this connector carries an approval with no script list, so no value was read. Approve it again at the operator's terminal: /mcp <id> probe, then /mcp <id> on

        vault_approval_unreadable:<path>: a script this connector was approved with cannot be read now, so nothing was launched and no value was read. Approve it again at the operator's terminal: /mcp <id> probe, then /mcp <id> on

        vault_approval_script_not_covered:<path>: this launch runs a script the approval does not cover, so nothing was launched and no value was read. Approve it again at the operator's terminal: /mcp <id> probe, then /mcp <id> on

        vault_approval_mismatch: this connector's program, arguments or scripts changed after the operator approved it, so nothing was launched and no value was read (approved <hex>, now <hex>). Approve it again at the operator's terminal: /mcp <id> probe, then /mcp <id> on

    (The hidden parameter names the connector's id, not one the model chooses; `<id>` is that id and
    `<path>` the script path in the manifest.)

14. From round 3 on, the SAME `mcp_vault_env_requires_operator` sentence (item 1) is also what a model
    reads for a vault definition it writes itself - the check now runs after the digest checks, and the
    sentence did not change.

### Operator-only strings (never a model's answer), round 3

15. The rendezvous log line, once at start, when a retirement cannot be verified because the key list is
    not in the environment:

        [rendezvous] WASM_AGENT_NETWORK_ADMIN_KEYS is empty: <n> stored retirement(s) cannot be verified and are NOT applied

    and the existing `[rendezvous] environment operator <id> retired by administrator <id>, approved by <id>`.

16. `secret_path_denied` (`lua/core/secret_guard.lua`) is unchanged in wording and now also covers
    `memory.db`, its `-wal`/`-shm` and the connector script directories, with its note

        credentials are reachable only through their connectors (mcp_google_*, mcp_whatsapp_*, email tools); an agent tool never reads them

    (that note is the pre-existing one for every root; the new roots reuse it rather than inventing a
    second sentence.)

### User-visible strings (the terminal, the window), round 3

17. The update banner - ONE definition, `update_banner.M.LINE`, with `/update` and `wa update` bold:

        Update available (<sha>) — /update here, or wa update in a terminal

18. The run status bar (CLI): `👣steps·step-time Δadded ↑input-total ↓output ◷run-time`, e.g.

        👣2·5s Δ12.3k ↑4.6M ↓310 ◷1:51

## Round 4 - the status bar's glyphs (18/11), and what the font actually has

`lua/core/cli_view.lua` names every glyph its two status rows draw in one table (`GLYPH`) and uses
Nerd Fonts' Material Design set, measured in Victor's terminal (JetBrainsMono Nerd Font) with fontconfig
on this node:

    4/4 font files: U+F0766 󰝦  U+F0A9F 󰪟  U+F0AA1 󰪡  U+F0AA3 󰪣  U+F0AA5 󰪥   (the context ball, 5 bands)
    4/4 font files: U+F0DFA 󰷺  U+F051B 󰔛  U+F0450 󰑐  U+F01BC 󰆼               (steps, clock, turns, cache)
    0/4 font files: U+25D1 ◑   U+25F7 ◷   U+1F463 👣   U+21BB ↻              (the four replaced)
    0/4 font files: U+2692 ⚒   U+2733 ✳   U+2737 ✷   U+2738 ✸   U+2739 ✹   U+23F0 ⏰
    4/4 font files: U+25D4 ◔   U+25C7 ◇   U+25C8 ◈   U+00B7 ·   U+0394 Δ   U+03A3 Σ   U+2191 ↑
                    U+2193 ↓   U+276F ❯   U+2014 —   and the box drawing

### Before / after, rendered through the view's own writer

A boxed `wa chat` at 100 columns, a run of three steps, the same probe script against both trees
(`WASM_AGENT_LUA_ROOT` selects the Lua tree, so the binary is the same and only the code differs):

    BEFORE (e8e9cd63)
      RUN  = 👣2·5s Δ24.3k ↑120.4k ↓1.0k ◷1:51
      BAR  = ✳ 👣2·0s Δ0 ↑0 ↓0 ◷0:00
      BAR^ = <ESC>[38;2;215;119;87m✳<ESC>[0m <ESC>[38;2;153;153;153m👣2·0s Δ0 ↑0 ↓0 ◷0:00<ESC>[0m<ESC>[K
      SUM  = ↻3 Σ↑120.4k ↓1.0k ◔12.2%/200.0k ◇75.20%

    AFTER
      RUN  = 󰷺2·5s Δ24.3k ↑120.4k ↓1.0k 󰔛1:51
      BAR  = ✳ 󰷺2·0s Δ0 ↑0 ↓0 󰔛0:00
      BAR^ = <ESC>[38;2;215;119;87m✳<ESC>[0m <ESC>[38;2;153;153;153m󰷺2·0s Δ0 ↑0 ↓0 󰔛0:00<ESC>[0m<ESC>[K
      SUM  = 󰑐3 Σ↑120.4k ↓1.0k 󰪟12.2%/200.0k 󰆼75.20%

The whole numbers line is ONE muted span (0x999999, the palette's secondary text) - the step pair was
already gray on this branch, so the brief's "today it renders blue" does not hold here; what is new is
that the gray is asserted. `Δ` and `↑` stay together, `Δ` first, as decided in round 3.

### The context ball, every band edge (rendered through `session_summary`)

    BEFORE                                          AFTER
     0     ↻3 Σ↑120.4k ↓1.0k ◔0.0%/200.0k ◇75.20%      0     󰑐3 ... 󰝦0.0%/200.0k 󰆼75.20%
     2.9   ↻3 Σ↑120.4k ↓1.0k ◔2.9%/200.0k ◇75.20%      2.9   󰑐3 ... 󰝦2.9%/200.0k 󰆼75.20%
     3     ↻3 Σ↑120.4k ↓1.0k ◔3.0%/200.0k ◇75.20%      3     󰑐3 ... 󰪟3.0%/200.0k 󰆼75.20%
     49.9  ↻3 Σ↑120.4k ↓1.0k ◔49.9%/200.0k ◇75.20%     49.9  󰑐3 ... 󰪟49.9%/200.0k 󰆼75.20%
     50    ↻3 Σ↑120.4k ↓1.0k ◔50.0%/200.0k ◇75.20%     50    󰑐3 ... 󰪡50.0%/200.0k 󰆼75.20%
     74.9  ↻3 Σ↑120.4k ↓1.0k ◔74.9%/200.0k ◇75.20%     74.9  󰑐3 ... 󰪡74.9%/200.0k 󰆼75.20%
     75    ↻3 Σ↑120.4k ↓1.0k ◔75.0%/200.0k ◇75.20%     75    󰑐3 ... 󰪣75.0%/200.0k 󰆼75.20%
     99.9  ↻3 Σ↑120.4k ↓1.0k ◔99.9%/200.0k ◇75.20%     99.9  󰑐3 ... 󰪣99.9%/200.0k 󰆼75.20%
     100   ↻3 Σ↑120.4k ↓1.0k ◔100.0%/200.0k ◇75.20%    100   󰑐3 ... 󰪥100.0%/200.0k 󰆼75.20%

(`...` is `Σ↑120.4k ↓1.0k`, unchanged; the full lines are in REPORT.md's captured output.) The band is
decided by ONE function, `M.context_ball(percent)`: 3%, 50%, 75% belong to the HIGHER band, and anything
at or over 100% - including a context measured past its window after a compaction - is the full ball. An
unmeasured percentage is the empty ball, not the full one.

### Tests, and what each proves

* `scripts/test-cli-view.lua` (415 checks, 379 before): the nine characters by codepoint; each at exactly
  one cell through `view_lib.columns` (the count `clip` and the status line use); the nine band edges plus
  140 and nil; the RENDERED boxed status row (glyph, clock, `Δ` < `↑` < `↓`, the step pair inside the
  secondary gray's SGR, no replaced character left); the RENDERED session bar in full.
* `rust/wa-term/src/terminal_editor.rs` `the_status_bar_glyphs_are_one_cell_each`: the same nine through
  `cell_width_of`, the function the box is laid out with, then the sample row's cell count == its
  character count and `clip_cells` keeps it whole at 40 cells. `cargo test -p wa-term`: 158 passed.
* On the base (a throwaway worktree at e8e9cd63, removed after the run, with this same test file): 33
  of 415 failed.

### Pre-existing, not this round

* `scripts/test-cli-wake-row.lua` 1 of 30 (`the snapshot matches what is drawn now`): the stored
  `tests/snapshots/balloon/wakes-80x24.txt` still says `↻0 ⚒️0 ↑0 ↓0`, which is older than `Σ↑` itself.
  Same failure on the base. Left alone on purpose (regenerating it would hide a pre-existing failure
  inside this commit).
* `scripts/test-cli-input.lua` 2 of 16, also identical on the base.

### Not changed, and why

* the SPINNER (`✶ ✳ ✷ ✸ ✹`): only `✶` is in his font, so four frames of five still fall back - the same
  size jump, once per tick. He picks the glyphs; one Material glyph per frame ends it.
* the self-wake row's `⏰` (U+23F0): not in the font either.
* the window (`ui/`, `scripts/probe-*.js`): it draws with its own font stack and already forces the text
  presentation of `👣`, so nothing there is drawn by a fallback face.

## Round 5 - the security verification of round 3 (19/11)

Three items from the review of `e8e9cd63`. Each one is fixed with a test that fails without the fix;
nothing from rounds 1-3 was reworded (the new model-visible strings are listed at the end for approval).

| # | hole | fix | test |
|---|---|---|---|
| 1 HIGH | `lua/core/mcp.lua` writes the whole launch to `<data>/mcp/requests/<uuid>.json`, `scripts/mcp-client-core.mjs` spawns `server.program`/`args`/`cwd` FROM that file with the vault values in its environment, `approval_problem` never reads it, and the directory was not in `secret_guard` - so a background loop rewrote `server.program` between the write and the read | the kernel reads the file, refuses unless its `server` is the program/arguments/cwd the operator approved, and gives the child the sha256 of the exact bytes it read; the child (`mcp-client.mjs`, `mcp-session.mjs`) hashes the bytes it read and refuses anything else before spawning; `<data>/mcp/requests` is in `secret_guard.ROOTS` | operations.rs `the_request_the_child_reads_must_name_the_approved_command`, `the_request_seal_is_the_sha256_of_the_bytes_the_kernel_read`; `scripts/test-mcp-request-seal.mjs` (5 tests, real processes: the smuggled program never runs) |
| 2 HIGH | "every script file the connector runs" was false: only an absolute arg with a script extension plus the runtime was hashed - a relative `conn.mjs` (resolved from the cwd), an extensionless program (`~/bin/conn`), `npx`/`uvx` package code and every imported/sourced module were not | the manifest is the CLOSURE of the code (form `mcp-vault-approval/v2`): a program outside the platform's roots is hashed whatever it is, every existing path argument is hashed, and each hashed file's local `import`/`require`/`source` is followed in turn; a connector whose code cannot be closed is REFUSED by name instead of approved, in the console and again in the kernel | test-mcp-vault-approval.lua (49 checks: the import is in the digest, an extensionless shebang program is covered, and a relative path, a bare program, a package runner, a bare import, a computed import and a python script are each refused); operations.rs `a_program_the_platform_does_not_own_must_be_in_the_digest`, `a_relative_path_or_a_package_runner_cannot_be_approved` |
| 3 LOW | the digest did not cover the cwd or the plain (non-vault) environment; `memory.db` and the script directories were refused with the credentials note; `image_roots` allowed the process's cwd even when that cwd is HOME | `cwd` and `env NAME=REF` lines in the canonical text (sorted); one note per kind of root; `image_roots_in` drops the cwd when it is the home | the canonical-text fixture digest on both sides, six assertions in test-mcp-vault-approval.lua (a moved cwd or another variable is another digest), host.rs `a_session_started_in_home_does_not_get_home_back_through_its_own_directory`, and a guard probe whose `checks`/`failed` are printed |

### 1. The request the child is spawned from

The approval has always described the CONNECTOR's command (`M.vault_manifest(definition, ...)`), while the
launch the kernel starts is `node mcp-client.mjs --request-file <file>` and the file is what decides
`server.program`, `server.args` and `server.cwd`. Two halves now meet:

* `seal_request` (`rust/wa-capabilities/src/operations.rs`) runs on every launch that names
  `--request-file`/`--seed-file`. For a vault launch it refuses unless the file's `server` names the
  approved program, the approved arguments (in order) and the approved cwd
  (`vault_request_program_mismatch`, `vault_request_arguments_mismatch`,
  `vault_request_cwd_mismatch`, `vault_request_environment_mismatch`,
  `vault_request_transport_not_checked`, `vault_request_file_not_covered:<path>`,
  `vault_request_program_not_covered:<path>`, `vault_request_path_not_absolute:<path>`,
  `vault_request_unreadable`, and `vault_request_unnamed` for a vault launch that names no file). It then
  puts the sha256 of the bytes it read in the child's environment (`WA_MCP_REQUEST_FILE`,
  `WA_MCP_REQUEST_SHA256`).
* the seam between the two is a test of its own: `scripts/test-mcp-request-shape.lua` (11 checks) asks the
  real console to build a request for a definition that names a vault entry and compares that file with
  the approval the same call carries - program, arguments, cwd, the environment (the definition's own
  references plus one self-reference per vault name) and the file list. Without it the two halves are
  proven apart from each other.
* the child reads the file ONCE and hashes those same bytes (`mcp_request_not_approved`,
  `mcp_request_path_mismatch`, `mcp_request_changed_since_approval`), so a rewrite after the kernel's read
  cannot reach a spawn - which is the whole attack, since the child inherits the vault values.

`<data>/mcp/requests` is now in `lua/core/secret_guard.lua`'s roots, so the plain routes (read/ls/grep/
write/edit, and a bash command naming it) are refused to the agent's own tools as well.

### 2. What "the code the connector runs" is, and what is refused

`M.vault_manifest` no longer asks "is this an absolute path with a script extension". It collects:

* the runtime (`M.RUNTIME`) and, in turn, everything each of those files imports;
* the definition's program, UNLESS it lives under a platform root (`/bin`, `/usr/bin`, `/usr/lib`,
  `/usr/libexec`, `/sbin`, `/usr/sbin`, `/usr/local/bin`, `/usr/local/sbin`, `/lib`, `/lib64`,
  `/nix/store`, `/snap`, `/opt/homebrew`, `/System`) - `/usr/bin/node` is the interpreter the connector
  runs ON; `~/bin/conn`, `<install>/bin/mail-mcp`, a script or a compiled binary anywhere else, is the
  connector's own code and is hashed, extension or no extension;
* every argument that is a path and exists as a file, plus the local modules each of those loads
  (`from './lib/x.mjs'`, `import('./x.mjs')`, `require('./x')`, shell `source`/`.`), recursively.
  An absolute path argument that does not exist yet is neither a problem nor a hole: the moment a file
  appears there, the manifest the gate recomputes changes and the approval goes stale.

A connector whose code cannot be closed is refused with `mcp_vault_code_not_covered` (and a `problems`
list) at the operator's own probe/on, instead of being approved with a digest that only looks complete:

    a relative script            conn.mjs / ./conn.mjs   "resolved from its own directory"
    a program that is a name     node                     "not an absolute path ... resolved through PATH"
    a package runner             npx uvx bunx pnpm yarn pipx corepack   "whose code comes from a cache or a registry"
    a bare package import        import x from 'left-pad' "whose code lives outside the files this approval can name"
    a computed import            import(name)             "loads code by a computed name"
    python/ruby/perl/ps/lua      conn.py                   "a language whose module system this digest cannot follow"

JavaScript (followed through its imports) and shell (followed through `source`/`.` of absolute paths) are
the two languages the digest CAN follow; anything else is refused rather than hashed and left open. The
kernel repeats the shape checks from the bytes on disk (`vault_approval_program_not_absolute`,
`vault_approval_package_runner`, `vault_approval_path_not_absolute`,
`vault_approval_program_not_covered`), so an approval minted before the rule cannot launch either.

A consequence worth naming: a vault connector's program must be ABSOLUTE. `/mcp <key> share` rewrites a
`.../node` program to this node's `node_program()`, which is the bare name `node` when nothing is
provisioned (`WA_NODE` unset, no `<install>/node`); such a row can no longer be approved, and the refusal
says which file the digest is missing. On the test node `node_program()` answers
`/home/victor/.local/share/mise/shims/node` (absolute, not a platform root - so it is hashed like any other
program), and `scripts/test-mcp-share.lua` pins an absolute `WA_NODE` for the one definition it approves.

### 3. cwd, the plain environment, the notes, and the cwd-as-HOME image root

The canonical text is now (both sides, fixture digest `7f39ce12...` pinned in Rust and Lua):

    mcp-vault-approval/v2
    program P
    cwd C
    env NAME=REF        (sorted by name)
    arg A ...           (in order)
    file PATH SHA ...   (sorted by path)
    vault NAME ...      (sorted)

so moving a connector, or adding a variable it asks for, voids the approval. The form is versioned and the
console refuses an older row with the sentence it already had for pre-digest approvals
(`mcp_vault_approval_missing`), the kernel with `vault_approval_digest_form` - a v1 digest is not compared
against a text it can never match. Cost, stated plainly: every vault connector needs the operator's
probe/on once after this upgrade.

`secret_guard` keeps the credentials sentence for the credential roots and now answers the matched root's
own reason: the node's store (`memory.db`), the connector code directories, and the launch request/seed
directory each get their own `note`. The credentials sentence itself is byte-identical.

`image_roots` is `image_roots_in(cwd, home)`: the session's own directory is allowed unless it IS the
home, which is what the review measured - a session started in HOME had all of HOME back through its cwd.

### Verified, with the commands

* `cargo test --lib -p wa-capabilities`: **313 passed, 0 failed** (307 before; six new tests, and the
  canonical-text fixture re-pinned for v2). `cargo check --workspace --all-targets`: no error (pre-existing
  warnings only).
* `node --test scripts/test-mcp-request-seal.mjs`: **5/5** - an unsealed request, a seal for other bytes and
  a seal for another path each refuse; the approved bytes really do spawn the fixture peer; and the attack
  (seal the honest bytes, then rewrite `server.program` to a program that writes a marker) is refused with
  the marker file absent.
* Lua suites, run with a scratch `WASM_AGENT_HOME`, a scratch `WA_MCP_SCRIPT_DIR` holding copies of the
  eight runtime files and `WASM_AGENT_LUA_ROOT=$PWD`:

      WASM_AGENT_LUA_ROOT=$PWD WASM_AGENT_HOME=<tmp> WA_MCP_SCRIPT_DIR=<tmp>/scripts \
        WA_SCRIPT=$PWD/scripts/test-mcp-vault-approval.lua wa --db <tmp>/v.db    # ok (49 checks)
      ... test-mcp-request-shape.lua 11 (the console's request vs the approval it carries)
      ... test-mcp-share.lua 44, test-mcp-command.lua 132, test-mcp-node-runtime.lua 142,
          test-mcp-native.lua 29, test-mcp-session-settlement.lua 22, test-codemode-blocks.lua 26,
          test-mcp.lua 48 (with MCP_TEST_SOURCE and WA_NODE), test-secret-guard.lua see below.
* The gate's own node set (`scripts/test.sh`, which now also runs the new file): 21 tests, 20 pass.
* A guard probe (`/tmp/guard-probe.lua`, printed as JSON): 10/10 - the request directory refused through
  read/write/bash and through the RESOLVED data path, the three notes distinct, the credentials note
  unchanged, an ordinary file still allowed.

### Pre-existing on this node (not this round)

* `scripts/test-mcp-runtime-closure.mjs` - "every MCP runtime list is the real import closure" fails with
  `Cannot read properties of null` because `scripts/install.sh` has no `MCP_RUNTIME` line: measured at
  `e8e9cd63` (`git show e8e9cd63:scripts/install.sh | grep -c MCP_RUNTIME` -> 0), and this round does not
  touch `install.sh`. It is a red gate line that predates the mission; named, not fixed.
* `scripts/test-secret-guard.lua` stops at "a script cannot read them either" with `codemode_not_enabled`
  (a binary built without `WA_CODEMODE_BUILD_ASSETS`). Confirmed pre-existing by running the BASE version of
  the file (`git show e8e9cd63:scripts/test-secret-guard.lua`) against this tree: the same line, the same
  error. The new checks in that file sit BEFORE that line and run; nothing failed before it.
* Round 4's `test-cli-wake-row.lua` (1 of 30) and `test-cli-input.lua` (2 of 16) are unchanged.
* `node --test` of the four-file set is red only because of the runtime-closure item above.

### Not verified, named

* No end-to-end vault launch on this node: no connector here names `vault_env`, and a test vault is not
  opened. The kernel half is tested on the real functions, the child half on real processes; the two halves
  are proven separately, never in one launch with a real value.
* The interpreter that runs the CLIENT (`node_program()`) is not in the digest - it is the platform's
  runtime, not the connector's code. An agent-writable `node` earlier on PATH would be a hole of the same
  family; it is named in `docs/VAULT.md` rather than hidden.
* Windows path forms (`C:\\...`) go through the same helpers and are covered by unit tests
  (`is_absolute_path`, `basename`, `platform_root`), but nothing was run on Windows this round.

### Every NEW model-visible string (rounds 1-3 strings are untouched; these need the same approval)

    mcp_vault_code_not_covered          note: "this connector runs code a digest cannot cover, so it was not
                                        approved: <problems>. A vault connector's program and every path it runs
                                        must be absolute, its imports must resolve to files beside it, and a
                                        package runner or a computed import is refused (docs/VAULT.md). Nothing
                                        was launched."
    mcp_vault_approval_missing          UNCHANGED sentence, now also used for a pre-v2 approval form
    vault_approval_digest_form          "this connector's approval predates the fields that say what it covers
                                        (its directory, its plain environment and every file it can load), so
                                        nothing was launched and no value was read. Approve it again at the
                                        operator's terminal: /mcp <id> probe, then /mcp <id> on"
    vault_approval_program_not_absolute   "its program is a bare name, which is resolved through PATH rather
                                        than named by the digest ... Name the absolute path of its interpreter or
                                        binary: /mcp <id> probe, then /mcp <id> on"
    vault_approval_package_runner       "its program is a package runner (<name>), whose code comes from a cache
                                        or a registry rather than from files an approval can name ..."
    vault_approval_path_not_absolute    "this connector runs a path relative to its own directory, which the
                                        digest cannot name ... Name its absolute path: /mcp <id> probe, then
                                        /mcp <id> on"
    vault_approval_program_not_covered  "this connector's own program is not a file the approval names ..."
    vault_request_unnamed / _unreadable / _transport_not_checked / _program_mismatch /
    _arguments_mismatch / _cwd_mismatch / _environment_mismatch / _file_not_covered /
    _program_not_covered / _path_not_absolute
                                        "the request this launch reads names a program (<p>) the operator did
                                        not approve (<q>), so nothing was launched and no value was read ..."
    mcp_request_unreadable / mcp_request_too_large   (the kernel's own launch refusals, same shape)
    mcp_request_not_approved / mcp_request_path_mismatch / mcp_request_changed_since_approval
                                        (what the child refuses; they surface as the answer's `error`)
    secret_guard notes, per kind of root:
      store    "this is the node's own store: it holds the MCP registry, every connector's approval and the
                session ledger, so an agent tool neither reads nor writes it (wa show / wa vault are the surfaces)"
      code     "this directory holds the code an approved connector runs: an agent tool neither reads nor writes
                it, so the bytes that were approved are the bytes that run"
      request  "these are the kernel's own per-launch request and seed files: a launch is spawned from the bytes
                the kernel read and approved, so an agent tool neither reads nor writes them"
    the coverage reasons quoted inside mcp_vault_code_not_covered (a relative path, a bare program, a package
    runner, a package import, a computed import, an unfollowable language, a file that cannot be read, code
    larger than an approval can cover).

---

# Round 6 - review of 6596aecc (18/11): every file the launch can run is in the digest

Round 5 closed the request-file gap; this round closes the rest of "every file it can run or load is in
the digest", which was not met. Nothing was pushed. All work happened on avell, in
@/home/victor/Work/missions/codeact-fix/wt@ (branch @change/codeact-fix@), with
@CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-codeact-fix@ and the pinned code-mode assets this node
already had (@WA_CODEMODE_BUILD_ASSETS=/home/victor/Work/missions/codeact-fix/codemode-assets@).

**Rebase first, as instructed.** @git fetch origin && git rebase origin/main@ (e5ba9089). Eighteen commits
replayed; the two conflicts the review named were the only ones: the root @REPORT.md@ (add/add) is now
DELETED from this branch on every replayed commit, so the branch adds none, and @docs/HOST.md@ keeps this
branch's @transcript_copy_first@ device. No root @REPORT.md@ is in this tree (@ls REPORT.md@: no such file).

| # | item | fix | the test that fails before and passes after |
|---|------|-----|----------------------------------------------|
| 1 | HIGH: the node interpreter (@WA_NODE@, @<data>/node/bin/node@, bare @node@) receives the vault values unhashed, and @<data>/node@ was not a guard root | the interpreter the launch spawns is resolved through @PATH@ and its realpath and hashed into the approval unless the platform owns it; @.wasm-agent/node@ is a @secret_guard@ root | probe @finding1@ (base @false@, here @true@) + @the_interpreter_the_launch_spawns_is_the_platforms_own_or_in_the_digest@ (new) |
| 2 | HIGH: @looks_like_path@ needs a slash or a script extension, so @args ["server"]@ ran @./server.js@ unhashed | every argument resolved as node resolves it (connector cwd, implied extensions) and hashed; unresolvable refused | probe @finding2@ (base @false@, here @true@) + @an_argument_is_resolved_from_the_connectors_own_directory@ (new) |
| 3 | HIGH: only @source@/@.@ followed; wrapper exec, JS @child_process@/@Worker@, inline @node -e@/@bash -c@ uncovered | named @exec@/@bash <file>@/@new Worker('literal')@ followed; inline code, command substitution, @exec@ of a value, @child_process@, @process.dlopen@, @new Function@ refused; the runtime exempt from the process rule only | probe @finding3@ x2 (base @false@/@false@, here @true@/@true@) + section 6 of @test-mcp-vault-approval.lua@ |
| 4 | MEDIUM: code files hashed before the spawn and never re-checked | @approval_problem@ returns the bytes it verified; @recheck_after_spawn@ hashes them again after @manager().start@ and KILLS the operation on a mismatch | @a_rewrite_between_the_check_and_the_spawn_is_caught@ (new; on the base the function does not exist) |
| 5 | MEDIUM: @/usr/local/bin@ and @/opt/homebrew@ are user-owned on macOS | a path is the platform's only when root-owned, not group/other-writable, and every directory above it the same (the prefix list only on Windows) | @the_interpreter_the_launch_spawns_is_the_platforms_own_or_in_the_digest@ + the @mcp.platform_owned@ probe (the base has no such rule) |
| 6 | MUST: four tests were in nobody's gate, and two write under @paths.data()@ | the four rows are in @scripts/test.sh@ (and every @scripts/test-*.lua@ is a fast-path candidate); each refuses to run unless @WASM_AGENT_HOME@ is a scratch home holding no @keys@/@secrets@ | @bash scripts/fast.sh@ with the four rows: see "Tests run"; the guard is quoted below |
| 7 | LOW: the two platform-root lists disagreed | @/System/@ is in both (@PLATFORM_ROOTS@ in Rust, @PLATFORM_ROOTS@ in @mcp.lua@), asserted by the new Rust test | @the_interpreter_the_launch_spawns_is_the_platforms_own_or_in_the_digest@ |
| 8 | rebase: @REPORT.md@ add/add; @docs/HOST.md@ | root @REPORT.md@ deleted on every replayed commit; the branch's @transcript_copy_first@ device kept | the rebase runs clean, @REPORT.md@ absent, @grep -c transcript_copy_first docs/HOST.md@ = 1 |

The approval form is now @mcp-vault-approval/v3@ on both sides (one canonical text, two implementations,
each side's test pins the same fixture digest @f45cc25f...@): a row approved under v2 is refused BY NAME
(@mcp_vault_approval_missing@ / @vault_approval_digest_form@) and the operator approves again, rather than
being compared against a text it could never match.

## 1. The interpreter the launch spawns (HIGH)

The hole. The console launches @node --request-file <f>@ where the program is @M.node_program()@ -
@WA_NODE@, then @<install>/node/bin/node@, then @<data>/node/bin/node@, then the bare name @node@ - and the
kernel puts the vault values in THAT process's environment (@operations.rs@, @control("start")@). The
approval hashed the definition's program instead, so @WA_NODE=/tmp/x@, a rewritten
@<data>/node/bin/node@, or a @node@ that is a user-owned shim on @PATH@ was code no digest named.
@<data>/node@ was also not in @secret_guard.ROOTS@, so an agent tool could replace it.

The fix. @M.vault_manifest@ resolves the interpreter through @PATH@ (@interpreter_path@) and its realpath
(@host.path_facts@) and:

* the platform's own is not hashed - ownership decides, not a prefix (item 5);
* anything else is hashed into the file list, by bytes read in chunks (@host.file_sha256@), so a
  hundred-megabyte binary never passes through Lua; a binary does not spend the script-bytes budget;
* the kernel checks the same thing from the launch itself: @vault_approval_interpreter_not_covered:<path>@
  when @launch.program@ (realpath) is neither the platform's own nor a file the approval names.

The evidence - one probe, two trees, and the cwd decides which @lua/core/mcp.lua@ @dofile@ finds:

@
--- base tree (f0afd356) ---
finding1_the_interpreter_is_in_the_digest=false
--- this tree (round 6) ---
finding1_the_interpreter_is_in_the_digest=true
@

The Rust half, on the base tree (base-only probes appended to a scratch worktree at f0afd356, never
committed), asks the kernel the same question:

@
thread 'operations::round6_base_probes::finding_1_the_interpreter_the_launch_spawns_must_be_covered' panicked at wa-capabilities/src/operations.rs:1471:9:
BASE HOLE: the launch spawns a user-owned interpreter while the approval names none: Ok(())
@

Here, the same launch is refused: @cargo test -p wa-capabilities vault_approval@ -> 13 passed, including
@the_interpreter_the_launch_spawns_is_the_platforms_own_or_in_the_digest@.

## 2. An argument that names a file (HIGH)

The hole: @looks_like_path@ answered only for a slash or a known script extension, so
@program /usr/bin/node, args ["server"], cwd /home/u/conn@ ran @/home/u/conn/server.js@ and the digest named
nothing.

The fix: @resolve_argument@ (Lua and Rust, the same rule): a name is resolved from the connector's own cwd
with the extensions node implies (@.mjs@, @.js@, @.cjs@, @/index.*@); what exists is hashed; an argument that
may name a file and cannot be resolved is REFUSED (a file that is not there when the operator approves can
be there at launch). The value of an option (@--mode stdio@) is a value, not a file; an option that names a
file (@--require@, @-r@, @--import@, @--loader@, @--env-file@, @--config@) has its value resolved and
hashed. Inline code (@-e@/@--eval@/@-p@/@--print@ for a JS interpreter, @-c@/@--command@ for a shell) is
refused by name.

Evidence: probe @finding2@ - @false@ on the base, @true@ here; the base Rust probe:

@
thread 'operations::round6_base_probes::finding_2_a_bare_argument_naming_a_file_must_be_covered' panicked at wa-capabilities/src/operations.rs:1485:9:
BASE HOLE: ./server.js runs while the approval names no such file: Ok(())
@

Here @an_argument_is_resolved_from_the_connectors_own_directory@ passes all five cases: named and covered,
resolved-but-not-covered (@vault_approval_argument_not_covered@), unresolvable
(@vault_approval_argument_unresolved@), inline (@vault_approval_inline_code@), and an option's value
(@--mode stdio@ stays approvable).

## 3. What a script runs in turn (HIGH)

The hole: the closure followed only @source@/@.@ (shell) and literal imports (JS), so a wrapper that
@exec@ed a second script, a JS @child_process@/@Worker@, a @.node@ addon by handle and inline @node -e@ /
@bash -c@ were code the digest never named.

The fix, in the closure (@M.vault_manifest@):

* FOLLOWED, so hashed in turn: @import@/@require@ of a local path, @new Worker('literal')@ (and
  @new Worker(new URL('literal', import.meta.url))@), shell @source@/@.@, @exec ./inner.sh@,
  @bash ./inner.sh@;
* REFUSED by name, with the file, as a coverage problem: @child_process@, a @Worker@ whose target is not a
  literal, @process.dlopen@, @eval(@, @new Function(@, shell @eval@, @sh -c@ / @bash -c@, a command
  substitution (@$(@ and backtick) and an @exec@ of a value - no digest of files can name a string that is
  evaluated;
* the node's OWN runtime (@M.RUNTIME@, eight files, every one hashed) is exempt from the @child_process@
  rule and from nothing else: it IS the harness that spawns the connector, and the request seal checks the
  program it spawns. The test's @mcp-client-core.mjs@ stub now carries a real
  @import { spawn } from 'node:child_process'@, so the exemption is proved rather than assumed.

Evidence: probes @finding3_a_connector_that_spawns_is_refused@ and
@finding3_an_exec_of_a_named_script_is_followed@ - @false@/@false@ on the base, @true@/@true@ here.

## 4. The bytes the child actually opens (MEDIUM)

The hole: the code files were hashed before the spawn and never again, so a rewrite landing between the
hash and the child's @open(2)@ was caught by neither.

The fix: @approval_problem@ answers the @(path, sha256)@ list it verified; @control("start")@ hashes those
same files again immediately after @manager().start@ and, on a difference or an unreadable file, CANCELS the
operation and returns @vault_approval_changed_since_check:<path>@ - its result is never returned.

What it does not do is stated in @docs/VAULT.md@ and @docs/MCP.md@: the two hashes are not one atomic step,
the window is milliseconds and it is not zero, and the operation may already have run when it is killed.

Evidence: @a_rewrite_between_the_check_and_the_spawn_is_caught@ writes, hashes, rewrites and asserts the
mismatch (passes here). The base has no such check at all:
@git show f0afd356:rust/wa-capabilities/src/operations.rs | grep -c recheck_after_spawn@ = 0 - which is the
"before" this item can have, and it is the honest one.

## 5. Ownership, not a prefix (MEDIUM)

The hole: @/usr/local/bin@ and @/opt/homebrew@ were platform roots, and on macOS both belong to the user, so
a homebrew interpreter was "the platform's" and received values unhashed.

The fix: a path is the platform's only when it is under a root AND root-owned AND not group/other-writable,
with every directory above it the same (@host.path_facts@ in Lua; @owned_by_root@ + @platform_owned@ in
Rust). On Windows there is no uid to read, so the prefix list alone decides - said in both docs.

Evidence: the new Rust test asserts @owned_by_root("/usr/bin")@, @platform_owned("/usr/bin/env")@,
@!platform_owned(<a user-owned temp file>)@ and that @/System/@ is in the list; the Lua test asserts the
same through the exported @mcp.platform_owned@ (probe @finding5_the_ownership_rule_is_exported@: @false@ on
the base, @true@ here).

## 6. The four rows, and the guard (MUST)

@scripts/test.sh@ now runs them, all in one scratch home:

@
WA_SCRIPT=$WASM_AGENT_LUA_ROOT/scripts/test-mcp-vault-approval.lua WASM_AGENT_HOME=$MCP_VAULT_HOME wa --db ... | grep 'mcp vault approval ok'
WA_SCRIPT=$WASM_AGENT_LUA_ROOT/scripts/test-secret-guard.lua      WASM_AGENT_HOME=$MCP_VAULT_HOME wa --db ... | grep 'secret guard ok'
WA_SCRIPT=$WASM_AGENT_LUA_ROOT/scripts/test-mcp-request-shape.lua WASM_AGENT_HOME=$MCP_VAULT_HOME wa --db ... | grep 'mcp request shape ok'
WA_SCRIPT=$WASM_AGENT_LUA_ROOT/scripts/test-mcp-share.lua         WASM_AGENT_HOME=$MCP_VAULT_HOME wa --db ... | grep 'mcp share ok'
@

All four are also candidates of the narrowed fast path (@scripts/lib/fast-rows.sh@ lists every
@scripts/test-*.lua@ not in @scripts/fast-path.exclude@).

The guard, the same in all four (exit 77 with a @SKIP@ line):

@lua
local scratch = tostring(host.getenv('WASM_AGENT_HOME') or '')
local data = dofile('lua/core/paths.lua').data()
local live = host.path_kind(data .. '/keys') == 'dir' or host.path_kind(data .. '/secrets') == 'dir'
if scratch == '' or data:find(scratch, 1, true) ~= 1 or live then
  print('SKIP refusing to write under ' .. data .. ' (set WASM_AGENT_HOME to a scratch directory)')
  os.exit(77)
end
@

Why the "real home" test is that one: the host sets @HOME@ to @WASM_AGENT_HOME@ for the interpreter, so the
naive @data == HOME .. '/.wasm-agent'@ test is always true and skipped every run (measured: it did, on the
first attempt, and the run printed @SKIP@ at once). A live node is recognised by what only a live node has -
its @keys@ / @secrets@ directories - plus the requirement that @WASM_AGENT_HOME@ was set at all.

Two more hermeticity fixes those rows needed: @test-mcp-share.lua@, pointed at a script directory without
the runtime, resolved the CHECKOUT's @scripts/@ and wrote @mcp-shared-fixture.mjs@ into it (measured, and
removed) - it now writes the runtime stubs and makes its own script directory when @WA_MCP_SCRIPT_DIR@ is
unset; and @test-secret-guard.lua@ used a @data@ variable before declaring it and printed a JSON line where
the gate greps an ok line (both fixed; it now also asserts the interpreter root).

## 7. The two platform-root lists (LOW)

@/System/@ is in @PLATFORM_ROOTS@ on both sides, and a Rust test asserts it, so the two lists cannot drift
apart again without a failure.

## 8. The rebase

@REPORT.md@ is deleted on every replayed commit (it was add/add against main's own), so this branch adds
none; @docs/HOST.md@ keeps @transcript_copy_first device@ next to @transcript_copy@. @git status@ was clean
right after the rebase, and @git log --oneline -3@ shows the round-5 commit on top of main's @e5ba9089@.

## Tests run

@
cd /home/victor/Work/missions/codeact-fix/wt/rust
CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-codeact-fix WA_CODEMODE_ALLOW_EMPTY=1 \
  cargo test --offline -p wa-capabilities vault_approval -- --test-threads=4
  -> test result: ok. 13 passed; 0 failed   (10 were there before; +3 for items 1, 2 and 4)
  
WA_FAST_ROWS=<the four rows> bash scripts/fast.sh
  -> binary built from this tree (b4653a4e, sha256 ced0a34e9ebf...), 6 of 231 Lua rows
  fast: lua 6/6 passed (56 excluded: scripts/fast-path.exclude)
  fast: rust wa-capabilities ok (35s)
  fast: prompt-docs ok, instructions ok, landing-queue ok, orphan-tests ok (every contract check still runs)
  fast result ok (42 checks, 0 failed, 0 skipped)
  fast path ok (42 checks, 0 skipped, 132s)
@

The four rows by hand, each in its own @mktemp -d@ home:

@
mcp vault approval ok (64 checks)
secret guard ok (36 checks)
mcp request shape ok (11 checks)
mcp share ok (44 checks)
@

## Texts to approve (verbatim)

New or changed text a model or the operator can read. Nothing else in the refusal vocabulary changed:
@mcp_vault_env_requires_operator@, @mcp_vault_approval_missing@, @mcp_vault_approval_stale@,
@mcp_vault_code_not_covered@ and every @vault_approval_*@ / @vault_request_*@ / @mcp_request_*@ sentence
from rounds 1-5 keep their words.

The form: @mcp-vault-approval/v3@ (was /v2).

New @vault_approval_*@ refusals (Rust, from the bytes and the launch):

@
vault_approval_inline_code:<flag>
  "this connector runs inline code (<flag>), which no digest of files can name, so nothing was launched and
   no value was read. Give it a script file: /mcp <id> probe, then /mcp <id> on"
vault_approval_argument_unresolved:<value>
  "this connector's argument may name a file this digest cannot resolve from its own directory, so nothing
   was launched and no value was read. Give its absolute path: /mcp <id> probe, then /mcp <id> on"
vault_approval_argument_not_covered:<path>
  "this connector runs a file the approval does not name, so nothing was launched and no value was read.
   Approve it again at the operator's terminal: /mcp <id> probe, then /mcp <id> on"
vault_approval_file_not_found:<value>
  "this connector names a file (<value>, after <option>) that is not there, so nothing was launched and no
   value was read. Give its absolute path: /mcp <id> probe, then /mcp <id> on"
vault_approval_interpreter_not_covered:<path>
  "the interpreter this launch puts the value in is neither the platform's own nor a file the approval
   names, so nothing was launched and no value was read. Name it at the operator's terminal:
   /mcp <id> probe, then /mcp <id> on"
vault_approval_changed_since_check:<path>
  "a file this connector runs changed between the check and the launch, so the operation was killed and no
   value was used. Approve it again at the operator's terminal: /mcp <id> probe, then /mcp <id> on"
@

The same argument and interpreter rules answer on the request path in the request's own words:
@vault_request_inline_code@, @vault_request_argument_unresolved@, @vault_request_argument_not_covered@,
@vault_request_file_not_found@ - the code name is the only change; the sentence is the one above with
"this request" for "this connector".

New coverage reasons inside @mcp_vault_code_not_covered@'s @problems@ list (Lua):

@
"its interpreter cannot be found (<program>), so no file this digest could hash runs it"
"its interpreter cannot be read (<path>)"
"an argument may name a file this digest cannot resolve (<value> from <dir>): give its absolute path"
"an argument names a file that cannot be found (<value> after <option>)"
"it runs inline code (<flag>), and no digest of files can name a string it evaluates"
"it starts a process (child_process), whose program no digest names"
"it starts a Worker whose target is not a literal module it names"
"it loads a native addon by handle (process.dlopen)"
"it evaluates a string as code (eval)"
"it builds a function from a string (new Function)"
"it evaluates a string as shell code (eval)"
"it execs a script chosen while it runs (exec of a value)"
"it runs inline shell code (<shell> -c)"
"it runs a command substitution, whose code no digest names"
"a file it runs cannot be hashed (<path>)"
@

(the existing "a file it runs cannot be read (<path>)", "its code is larger than an approval can cover
(<path>)", "an argument is a path resolved from its own directory (<value>): only an absolute path can be
covered", and the package / import / language reasons are unchanged).

The new secret root, and its note (@secret_guard.NOTES.runtime@):

@
root: '.wasm-agent/node'
note: "this is the interpreter the node runs its connectors on: the process a vault value is put in, so an
       agent tool neither reads nor writes it"
@

Two new host capabilities, with their one-line descriptions in the capability inventory and docs/HOST.md:

@
path_facts     "A path's realpath, kind, size and (on unix) owner and mode bits, as JSON"
file_sha256    "SHA-256 of a file's bytes, read in chunks; nil plus a named reason when it cannot be read"
@

Docs: the "what an approval covers" section of @docs/MCP.md@ and of @docs/VAULT.md@ is rewritten to say
exactly what is covered, and a paragraph of its own - "What the digest does not promise" - says what it does
not: the two hashes are not atomic, a platform interpreter is trusted by ownership rather than hashed, on
Windows the prefix list decides, a binary is hashed and not parsed, and an approval row can still be forged
by a hand that can write @memory.db@.

## Not run, and limits

* No deploy, no push, and no other node: the build and every run are on avell.
* The full @scripts/test.sh@ gate was not run end to end (it is the nightly, ~50 minutes, plus the release
  build and the components this tree needs): the four new rows ran by hand and through @scripts/fast.sh@,
  and @cargo test -p wa-capabilities@ ran in full.
* The vault itself is never opened by any test here: every vault test stubs @host.operation@ or refuses at
  the gate before a value is read, so "a value is never read" is proved at the refusal, not against a live
  vault.
* @test-mcp-vault-approval.lua@ hashes a fixture interpreter it owns; a real hundred-megabyte node binary is
  hashed through @host.file_sha256@, which the probe above exercised on @/usr/bin/env@, not on a node build.
* The macOS half of item 5 (/usr/local/bin, /opt/homebrew user-owned) follows from the uid and mode bits and
  is asserted here by rule on this Linux node - a user-owned file is not the platform's, a root-owned
  directory is - not on a macOS host.
