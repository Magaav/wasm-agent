# change/edit-accepts-common-names - a call with the other well-known argument names works the first time

Branch `change/edit-accepts-common-names` in /home/victor/Work/missions/edit-accepts-common-names/wt, base
a9d4617d, one commit: **ea51a852**. Built and tested on avell (16 cores) with
`CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-edit-accepts-common-names`. Nothing was pushed; no other
node was built or tested on.

## The short version

| # | the job | the fix | the test that fails on the base |
|---|---------|---------|----------------------------------|
| 1 | `edit` accepts `old_string`/`new_string` for `old_text`/`new_text`, one top-level pair as a one-item `edits`, `file_path` for `path`; same checks after mapping; a call that mixes both spellings is refused by name | `lua/core/file_tools.lua` (`ALIASES`, `rename_fields`, `M.accept_names`, item mapping in `M.edit`) and `lua/core/tools.lua` (the read/write/edit dispatch branches map before `resolve_path`) - ea51a852 | `scripts/test-edit-aliases.lua` (discriminates: on the base code the first check answers `unsupported_edit_option` for `old_string`) |
| 2 | the schema the model is sent does NOT change (prompt cache) | no schema table was touched; `git show ea51a852 -- lua/core/tools.lua` is the dispatch branches only | section 7 of the row asserts `old_string`/`new_string`/`file_path` are absent from `catalog('master')`'s edit parameters, and `path`/`edits`/`range_edits` present |
| 3 | a refusal for a truly unknown argument names the accepted ones in its first line | `lua/core/refusal.lua` `unsupported_edit_option`, `unsupported_replacement_field`, `unsupported_range_edit_field` - ea51a852 | section 6 asserts the first line names `old_text` and `file_path` |
| 4 | tests that fail on the base for each accepted spelling | the row above, six spellings | `bash scripts/test-discriminates.sh a9d4617d --json` verdict `discriminates` (quoted below) |

## The measurement the brief asked for - and why its number is UNKNOWN, not zero

The brief asks to "count in the ledger how many edit/read/write calls failed on an argument NAME in 3 days".
I could not take that count on this node, and I am not going to write a number I did not measure. The three
reasons, each measured this session:

1. **The ledger's own text index answers nothing.** `search_messages` returns 0 hits for `the`, for `edit`, and
   for `secret_path_denied` - a string this very session's own tool result carries - with and without a
   time window. `scripts/fast-path.exclude` already lists `scripts/test-history-search.lua` as out of the
   fast path, so the index's emptiness is not new; a count read through it would be a claim about an empty
   index, not about the last three days.
2. **The store itself is guard-refused to agent tools.** `bash` on `~/.wasm-agent/memory.db` answers 403
   `secret_path_denied` (`lua/core/secret_guard.lua`): the ledger holds the session history, so an agent
   tool neither reads nor writes it. I did not work around the guard.
3. **The only remaining door is per-session paging, and the window does not fit.** The 3-day window holds
   **100 sessions and 17,947 messages** (`sessions` pages all 100 in one page, every one with
   `updated_at >= now - 3d`). Paging them through `session view=tool_calls` is ~16 KB per page, i.e. about
   1,700 page reads; a 25-session scan was stopped by the sandbox's own budget after ~23 pages
   (`TimeoutError: the script was stopped while computing`). A bounded sample of the two newest sessions
   (68 tool rows, 3 failed rows) contained no argument-name refusal at all - today's failures were shell
   and script-syntax ones.

So the count stays **unknown**, and the scope below follows from that: only the names the brief itself
names were accepted.

### The brief's own premises, re-measured

* `lua/core/tools.lua:454` is the `edit` schema on the base, and it declares `path`, `edits`, `range_edits`
  only. **Correct.**
* The brief's "edit takes `edits = [{old_text,new_text}]`" was **incomplete**: the base already accepted a TOP-LEVEL
  `old_text`/`new_text` pair (`lua/core/file_tools.lua:500`, `allowed={path,version,range_edits,edits,
  old_text,new_text}`). What was missing is the name the note quoted: `old_string`/`new_string`, and
  `file_path` for `path`. The turn note's own words are the accurate evidence.
* `old_string` appears **0 times** in the base `lua/core/file_tools.lua`, so on the base the alias is a
  refusal, not a silent no-op. The discriminates run below prints that refusal.

## 1. What the diff does (ea51a852)

* `lua/core/file_tools.lua`: `ALIASES` (`read`/`write`: `file_path`->`path`; `edit`: `file_path`->`path`,
  `old_string`->`old_text`, `new_string`->`new_text`), `rename_fields`, `M.accept_names(tool, args)`, and the
  same mapping for each replacement inside `edits` (`EDIT_ITEM_ALIASES`). The mapping runs BEFORE the checks,
  so a mapped call meets exactly the checks the declared names meet: one occurrence, the anchor fence, the
  version, `old_text_required`, `new_text_required`, `old_text_ambiguous`.
* `M.accept_names` is called at the top of `M.read`, `M.prepare_write` and `M.edit`, and in the dispatcher's
  `read`/`write`/`edit` branches **before** `resolve_path`, so `file_path` resolves, fences and records as
  `path` does. Two mappings of the same call are one mapping (the first leaves no alias key behind).
* Both spellings in one call is refused by name, `argument_alias_conflict`, naming the argument and its
  synonym - never resolved by picking one. The code is in `lua/core/refusal.lua` and in the regenerated
  `lua/core/refusal_codes.lua` (`argument_alias_conflict` -> `file_tools.lua`).
* Why `read`/`write` too: code mode already renamed `file_path` -> `path` for every tool
  (`lua/core/json_contract.lua:197`, `SYNONYMS`), so inside a script `tools.read({file_path=...})` already
  worked while the same call in `wa chat` answered `path_required`. The direct path now agrees with the
  script path. **No other tool gained a synonym**, because the count that would justify more is the count
  this node could not give.
* Not in the schema, on purpose: the synonyms are tolerance at the door. A schema that declares them is the
  prompt prefix, paid by every session.

## 2. Verification

* **The row passes on this tree.** `scripts/fast.sh` (narrowed to this row, core rows included):
  `lua 17/17 passed`, `fast path ok (92 checks, 0 skipped, 406s)`, and in the run's own result file
  `scripts/test-edit-aliases.lua` = `status: pass, ms: 1775` - beside
  `scripts/test-refusal-contract.lua` = `pass` (so the regenerated inventory is fresh and every `fix`
  names only things this tree has) and `scripts/test-tool-schema-fidelity.lua` = `pass`.
* **The row discriminates.** `bash scripts/test-discriminates.sh a9d4617d --json` (WA_BIN = this tree's
  binary): `{"verdict":"discriminates","test":"scripts/test-edit-aliases.lua","reason":"lua error:
  [string \"scripts/test-edit-aliases.lua\"]:37: edit with old_string/new_string is the same request:
  {\"error\":\"unsupported_edit_option\"...` - `1 discriminating, 0 blocking`.
* **Where the new row is wired:** `scripts/test.sh:1444` (an explicit `WA_SCRIPT` row with its own
  `--db "$DB.edit-aliases"`) and `scripts/lib/fast-rows.sh:61` (the never-dropped core rows, so a narrowed
  run still runs it); the fast path's `scripts/test-*.lua` glob also picks it up by default.
* **Hermetic:** its own scratch `WASM_AGENT_HOME` (refuses the operator home by name, the same guard as
  `scripts/test-read-truncation.lua`), fixtures under `paths.data()`, no network, no peer, no fleet call.

## 3. Texts to approve (verbatim, model-facing)

New code, rendered when a call sends both spellings (site text, `lua/core/file_tools.lua`):

1. message: "`<tool>` was sent both `<argument>` and its synonym `<alias>`, so which value to use is not decidable."
2. fix: "send `<argument>` once and drop `<alias>`; nothing was changed."
3. input: "`<alias>` and `<argument>`"

New code, template when no site text is given (`lua/core/refusal.lua`):

4. message: "`{tool}` was sent both one argument's own name and its synonym, so which value to use is not decidable ({origin})."
5. fix: "send the argument once, under either name; nothing was changed."

Changed first line (`lua/core/refusal.lua`):

6. `unsupported_edit_option` message: "`edit` does not take the option `{input}`; it takes `path` (or `file_path`), `edits`, `range_edits`, `old_text`/`new_text` (or `old_string`/`new_string`) and `version` ({origin})."
7. `unsupported_edit_option` fix: "drop `{input}`; send `{\"path\":\"...\",\"old_string\":\"...\",\"new_string\":\"...\"}` or `{\"path\":\"...\",\"edits\":[{\"old_text\":\"...\",\"new_text\":\"...\"}]}`."
8. `unsupported_replacement_field` message: "a replacement carries a field this node does not accept: `{input}`; a replacement takes `old_text` and `new_text` (or `old_string`/`new_string`) ({origin})."
9. `unsupported_range_edit_field` message: "a range edit carries a field this node does not accept: `{input}`; a range edit takes `selection`, `replacement_lines`, `start_line` and `end_line` ({origin})."

No operator-facing string changed.

## 4. Not done, and what is still unknown

* **The 3-day count of argument-name failures is unknown** (section above): the text index is empty, the
  store is guard-refused, and per-session paging does not fit one script's budget on a node with 17,947
  messages in three days. If an operator wants that number, the cheapest honest route is a supported
  read-only verb over `messages`/`harness_events` (the shape `wa turns` and `wa counters` already use), not
  a wider agent tool.
* Therefore **no other tool gained a synonym**: the brief's "do the same for any other tool your count shows
  above 3 failures" has no count behind it. `grep`'s `unsupported_search_option` still does not name the
  names it takes in its first line (`lua/core/refusal.lua:397`) - left alone rather than guessed at.
* The `edit` schema description still says `edits` `(old_text/new_text)` and does not mention the top-level
  pair the tool has accepted all along; changing it would change the prompt prefix, so it is a decision for
  the operator, not for this branch.
* The row asserts `oldtext`/`newtext` are not advertised in the schema; it does not accept those spellings,
  because the brief does not name them and no measurement says models write them here.
