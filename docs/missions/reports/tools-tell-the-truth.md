# tools-tell-the-truth: a tool never answers as if all is well when it is not

Mission: Fable + Victor, 25/11 (first after the v0.1.2 cut, one worker). Branch `change/tools-tell-the-truth`,
based on origin/main `70eb209d`. Every row below was run on this node (avell) with the tree's own binary.

## 0. What the brief got wrong (premises re-measured before writing code)

| premise | measured | verdict |
|---|---|---|
| "the count and the list disagree" (item 1) | `rust/components/wa-whatsapp/src/index.rs:1881` answered `matched = total` beside `count = candidates.len()` and `truncated = total > candidates.len()`; a fold of one person under two addresses (named in `same_person`) also set `truncated` | TRUE, and wider than reported: the fold made an answer say "truncated" that hid nothing |
| "search_messages accepted an unknown key q" (item 2) | 51 of the 57 host tools declared arguments and accepted ANY extra name (the handler dropped it); 4 declared none and accepted anything; 1 refused (`capabilities`, declared in item 4 of this mission); 1 was explicitly open (`remote`). Table in section 5 | TRUE; the earlier mission had built the rule but shipped it report-only (`lua/core/tool_arguments.lua`, `M.ENFORCE = 'off'`) |
| "one failing call aborts the block and a finished result is lost" (item 3) | the failure answer carried `error` + `fix` naming the calls that ran ("Already done, not undone: time.") and NOT their results; the results sat in `tool-results/<sha>.txt` with no path to them but the hash | TRUE as written; the calls were named, their answers were not |
| "capabilities() returns every entry" (item 4) | `lua/core/tools.lua` answered `{role, capabilities[], execution{}, workspace, note}` for the whole catalogue (57 entries on this node, 90 with connections installed), with no filter | TRUE |
| "the pinned message is cut without a sign" (item 5) | `rust/wa-term/src/transcript.rs` `pin_line` took the request's FIRST non-empty line and the caller clipped a wide line with U+2026 (one glyph); a multi-line request was cut with no mark at all | TRUE |

## 1. Item 5 — the pinned request says it was cut (`92d32ddc`)

`pin_row` (was `pin_line`) now ends the row with three literal dots (`PIN_MARK = "..."`) when the request
carries more than one line, and when its only line is wider than the window; the room for the mark is
reserved BEFORE the text is cut, by display cells, so the row never overflows. A one-line request that fits
ends with nothing: the mark means "there is more".

Row: `cargo test --release -p wa-term --lib` — **223 passed, 0 failed**. The new test is
`transcript::tests::a_pinned_request_longer_than_one_line_ends_in_three_dots` (it also asserts the one-line
case carries no dots); `transcript::tests::a_long_wide_request_is_one_row_clipped_with_an_ellipsis` used to
pin the one-glyph ellipsis and now pins the three dots — updated, not loosened (it still asserts the row says
it was cut, and adds that the old glyph is gone).

## 2. Item 1 — the count and the list agree, or the hidden ones are named (`a5537d11`)

The answer counts what it NAMES once: the candidates plus every chat folded into an earlier one as
`same_person`. What is left of `matched` is a chat the answer could not show, and the only thing that can
leave one out without naming it is the caller's `limit` (a fold never drops a chat it does not name). So
`truncated` now means exactly "there is a match this answer does not name", `hidden` is how many, and
`hidden_why` says both numbers and the way to see them.

Row: `cargo test --manifest-path rust/components/wa-whatsapp/Cargo.toml` — **209 passed, 0 failed**. New:
`index::tests::a_limit_that_hides_matches_says_how_many_and_why`; `one_person_under_a_lid_and_a_number_is_one_candidate`
gained the fold-hides-nothing assertions (`matched: 2`, `count: 1`, `truncated: false`, no `hidden`).

## 3. Item 3 — a failed block hands back what it finished (`f7cecf21`)

A failed `run` block now carries `done`: one entry per settled call, in the order the script made them,
`{n, id, name, ok, result}`, plus `done_note`. Bounded twice (1200 bytes per answer, 4000 for the block so
a failure never costs more context than a success); an answer over that is a POINTER, never a silent cut:
`unread {sha256, offset, bytes}`, readable with `tool_result`. A healthy block gains nothing: no `done`, no
`done_note`, the same keys as before, and the change sits inside the failure branch of the presentation
(`finish`) only — the request path, the sandbox protocol and the input bytes are untouched.

Row: `scripts/test-codemode-failure-results.lua` — **17 checks, 0 failed**; it reads the pointer back from
its last page. Re-ran with this change: `test-codemode-errors.lua` (10), `test-codemode-globals.lua` (27),
`test-codemode-blocks.lua` (89), `test-codemode-friction.lua` (21) — all green.

## 4. Item 4 — one fact costs one entry (`4821c322`)

`capabilities` takes `names` (exact names) and `status` (the exact workspace status word) and answers only
those entries, in the catalogue's own order, with `filter {names, status, matched, total}`. No arguments
answers exactly what it answered before (same keys, same order, same bytes). The guest global and the outer
tool are one code path. Every ask that cannot be answered is refused by name: `unknown_capability` (+ the
names), `capabilities_names_required`, `unknown_capability_status` (+ the words that exist),
`capabilities_status_required`.

Row: `scripts/test-capabilities-filter.lua` — **94 checks, 0 failed**, through real run blocks plus the
outer tool; its own output: `{"catalogue":66,"checks":94,"ok":true,"status":"not_blocked"}` (a scratch home
carries 66 tools; the live node 57 host + 43 connector).

## 5. Item 2 — an argument name the tool does not declare is refused, with the name that was meant

### 5.1 The report first: what accepted unknown keys on this node, before the rule

Measured at `4821c322` (after item 4, before item 2), `tools.all('master')` on the live home:
**100 tool definitions**, in five shapes.

**A. Refused already (1):** `capabilities` — closed by item 4 of this mission (`additionalProperties = false`).

**B. Open by declaration (1):** `remote` — `additionalProperties: true`, because it forwards its capability's
own arguments; the fields it carries are the capability's, judged by the capability's schema.

**C. Declared arguments, accepted any extra name (51).** The handler dropped the value and the call ran as a
different call:

    bash (4 declared); capture_inspect (7); client (15); codemode (2); diagnose (1); done_criteria (8);
    edit (4); fleetview (1); forget (1); grep (8); lessons (10); ls (2); memories (2); node_update (7);
    notes_append (1); notes_compact (1); notes_read (2); notes_write (1); operation (12); read (6);
    recall (3); remember (4); resource (5); resume_session (2); run (2); search_messages (15); services (9);
    session (13); session_debug (2); session_fixture (1); session_worktree (3); sessions (4); shell (3);
    skill (5); spell_compose (3); spell_export (4); spell_forget (1); spell_get (1); spell_run (2);
    spell_save (7); subagent (25); tool_call (5); tool_result (3); tool_search (3); wake (7); wake_cancel (1);
    wake_list (1); wave_autoflush (10); web_read (6); web_search (3); write (3)

**D. Took no arguments at all, and accepted anything (4):** `build`, `nodes`, `spell_list`, `time`.

**E. Connector and peer tools, judged by the CONNECTOR's own schema (43, listed separately).** The host never
refuses these for a name it does not know; it validates the call against the schema the connector or the peer
published, which is what `validate` walks for them:

    mcp (4 declared); mcp_whatsapp_backfill (2); mcp_whatsapp_contacts (2); mcp_whatsapp_download (3);
    mcp_whatsapp_media (2); mcp_whatsapp_reactions (2); mcp_whatsapp_read (3); mcp_whatsapp_search (7);
    mcp_whatsapp_send (10); peer_work__mcp_colmeio-cloud_* (22 tools, 0-11 declared);
    peer_work__mcp_google_imap_* (12 tools, 0-15 declared); peer_work__mcp_google_smtp_* (4 tools, 1-11);
    peer_work__mcp_google_list_all_accounts (0)

### 5.2 The rule, in one place

`lua/core/json_contract.lua` (`validate`): an object schema that declares arguments is **closed** unless it
says otherwise — `additionalProperties: true` or a schema. Anything else (absent, or false) refuses a name
outside `properties` with `unknown_argument:<name> - did you mean <nearest>?`, the nearest name coming from
the schema's own properties by edit distance (only when it is close: half the word sent, at least 2, so a
misleading guess is never made). A set of names the caller knows the tool takes without the schema saying so
is passed in as a third argument — one list, `lua/core/tool_arguments.lua` `INTERNAL` (the runtime's own
fields and the synonyms the handlers map), used by the two loops that hand a model's text to the contract.

`lua/core/refusal.lua` renders it: the code carries the key and the suggestion, the renderer repeats both in
the sentence, so no site restates them.

`lua/core/tool_arguments.lua`: the dispatch door now says the same thing (`unknown_argument:<name> - did you
mean <nearest>?`, `effect: "none"`, plus the names the tool takes) and `M.ENFORCE` ships `'model'`: a call
THE MODEL sent is refused; internal and peer callers stay report-only, because their fields are the runtime's
own and a peer call is judged by the peer's schema.

### 5.3 What changed in the rows that encoded the old behaviour (not loosened)

* `scripts/test-tool-arguments.lua` section 1 asserted "an undeclared field does not refuse the call" — it
  was the STEP 1 measurement. It now asserts the refusal, `effect: none`, the names the tool takes, the
  suggestion for a name one letter from a declared one, and a refusal with NO suggestion for a name far from
  every declared one. 35 checks (was 32).
* `scripts/test-edit-aliases.lua` expected the handler's `unsupported_edit_option` again; it now expects
  `unknown_argument:old_txt` plus `effect: none`, as it did when the validator was on.
* `scripts/test-tool-schema-fidelity.lua` section 4 asserted `schema_extra:arguments.query` and "an open
  schema accepts what it does not name" for a schema with NO `additionalProperties`. It now asserts
  `unknown_argument:query`, the suggestion for a name one letter off, the accepted names through the
  renderer, that a schema that declares arguments is CLOSED by default, and that an explicitly open schema
  still accepts what it does not name. 71 checks (was 69).

### 5.4 Rows

* `scripts/test-unknown-argument.lua` (new) — **18 checks, 0 failed**: a script's call is refused by name
  with the name meant and the file it would have written does not exist (nothing ran); the same call through
  the outer door answers the same code and the same suggestion; an open forwarding schema (`remote`) is NOT
  refused for a key the host does not declare; a closed schema refuses where the handler used to ignore the
  key; a healthy call answers as it always did.

## 6. Texts to approve (everything a person or the model reads)

1. Pinned row mark: `...` (three literal dots) — appended when the request is longer than one line or wider
   than the window. Nothing else in that row changed.
2. `hidden` (integer) and `hidden_why`, the contacts answer:
   > this answer names {named} of the {total} chats whose name matches; ask again with limit:{total} to see
   > all of them
3. The failed run block's `done` entries `{n, id, name, ok, result}` / `unread {sha256, offset, bytes}` and
   `done_note`:
   > done: the calls that finished before this error, in order, with the answer each one produced. Read them
   > instead of running the work again. An entry that carries `unread` instead of `result` is an answer too
   > large for this block, and tool_result(sha256,offset,limit) reads it byte for byte.
4. `capabilities` description and its two arguments:
   > List permitted tools and their current workspace execution limits; permission is not executability. With
   > no arguments: the whole catalogue. With names or status: only those entries, so one fact costs one entry
   > instead of ninety.
   > `names`: Only these tools, by exact name. A name this catalogue does not carry is refused by name, never
   > dropped from the answer.
   > `status`: Only the entries whose workspace execution status is this exact word.
5. `capabilities` refusals:
   > capabilities_names_required — `names` is a non-empty array of exact tool names; omit it to ask for the
   > whole catalogue.
   > unknown_capability — Nothing is listed: a name this catalogue does not carry is named here rather than
   > dropped from an answer that would look complete. searchTools finds a tool by what it does.
   > capabilities_status_required — `status` is one workspace execution status word; omit it to ask for every
   > entry.
   > unknown_capability_status — `status` is one of the workspace execution statuses this catalogue carries;
   > accept is the list, and no arguments is every entry.
   > the filtered answer's `filter.note` — Only the entries the filter names are listed; capabilities() with no
   > arguments is the whole catalogue.
6. The unknown-argument refusal, both doors:
   > code: `unknown_argument:q - did you mean query?` (the suggestion only when the name is close)
   > message: `<tool>` does not take the argument `<name>` - its own schema never declares that name, so
   > nothing was dispatched (json_contract.lua).
   > fix: drop `<name>`, did you mean `<near>`?; <tool> takes <names>.
   > the dispatch door's own words: `<tool>` does not take the argument `<name>` - its own schema never
   > declares that name, so nothing ran. It declares: <names>.

## 7. Base discrimination (rule 16): every new or changed row fails on the base

Base worktree `/tmp/tt-base` at `70eb209d` (own build: `/home/victor/wasm-agent/target/m-tt-base`), the
branch's TEST files copied in, the base tree's own Lua and binary:

| row | on the base | why |
|---|---|---|
| `test-unknown-argument.lua` | RED — "the call was refused by the name it sent: null" | base accepts the undeclared name and runs the call |
| `test-capabilities-filter.lua` | RED — "only the named entries…: [time, remember, …]" | base ignores `names` and answers the whole catalogue |
| `test-codemode-failure-results.lua` | RED — "both calls that settled are listed: (nothing)" | base answers no `done` |
| `test-tool-schema-fidelity.lua` | RED — 4 failed ("a schema that declares arguments is closed unless it says otherwise") | base treats an absent `additionalProperties` as open |
| `test-tool-arguments.lua` | RED — "a name one letter from a declared one is refused WITH the name meant" | base records and runs |
| `test-edit-aliases.lua` | RED — the handler's `unsupported_edit_option` | base never reaches the contract |

Rust rows: `wa-term` and `wa-whatsapp` were not re-run against the base by me — the new tests name constants
(`PIN_MARK`) and fields (`hidden`) that the base does not have, so they cannot pass there; `scripts/test-discriminates.sh`
at the land gate is the authority.

## 7b. Failures that are NOT this branch (run on the base too)

Under the single-row runner I used (its own scratch home, the tree's binary, `cwd` = the repo root), three
rows fail the same way on the BASE commit, so they are this node/runner and not this change:
`test-done-gate.lua` (30 failed / 89 checks on the base and on this branch), `test-resource-claims.lua`
("unknown fixture mode"), `test-native-target-resource.lua` (a nil root). `test-remote-refusals.lua` and
`test-mcp.lua` fail in the runner for a missing `policy.json` / MCP config in the scratch home.

## 8. What I could not verify (and did not do)

* **A real connector and a real peer.** The one rule is proved against a forwarding TOOL (`remote`, open by
  declaration) and against the host's own schemas, never against a live MCP server or a second node (mission
  rule: no live fleet from work). A connector whose published schema is NARROWER than what it accepts will now
  be refused locally for the difference; `additionalProperties: true` in its schema is the fix, and no such
  connector was measured here.
* **The full fast path on this exact commit** — started twice; the first operation never spawned a
  process, the second is queued behind another mission's `fast.sh` holding `~/Work/missions/.suite.lock`. Its
  verdict is in section 9 only if it completed before this report was written; the rows I ran singly are
  listed where they are (about 40).
* **A connector's real schema.** No live MCP server or peer was contacted (mission rule). The one rule is
  proved against the schemas on this node and against a forwarding tool.
* **The TUI row by eye.** Item 5 is proved by `cargo test`, not by looking at a terminal: the three dots on a
  real multi-line message followed by scrolling it out of view.
* `scripts/test-discriminates.sh` (base discrimination for the whole branch) was not run by me; the land
  gate runs it.
