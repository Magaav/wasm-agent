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
