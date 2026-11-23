# tool-args-honest-and-same-on-peers

Branch `change/tool-args-honest-and-same-on-peers`, base `c1337903`. Two "what hurt" notes from real
sessions and Victor's rule that peer calls behave exactly as local ones. Everything below was measured on
avell with the tree's own binary (never on a live peer).

## 1. Re-measured first: which premises held

| Premise in the brief | Measured at `c1337903` | Verdict |
|---|---|---|
| bash declares `command, cwd, timeout_seconds`; no stdin anywhere | `lua/core/tools.lua:461` (base) | TRUE |
| grep declares `pattern, path, ignore_case, limit, max_depth, extensions`; no context | `lua/core/tools.lua:501` (base) | TRUE |
| "no unknown-argument refusal exists in tools.lua / envelope.lua / codemode.lua; an unknown field is not refused anywhere" | three handlers DID refuse, inconsistently: `grep` with `unsupported_search_option` (`tools.lua:2200` base), an edit item's fields with `unsupported_replacement_field`, and `operation start` with `operation_unknown_field` (`rust/wa-capabilities/src/operations.rs:1305`) | **FALSE as written** — most tools dropped the field silently, three refused it by name. The inconsistency is what the one validator removes |
| `wa_peer_dispatch` ends in `toolslib.dispatch` | `lua/core/server.lua:1671` (base), dispatch at 1697 | TRUE |
| `adopt_bash` is a second implementation that forwards only command/cwd/timeout_seconds | `lua/core/server.lua:1350` (base) | TRUE |
| item 4's "same bound as write's content" | write's `content` has no declared and no enforced bound (no `maxLength`, and `host.write_file` takes any string) | **STALE** — I chose 1 MiB, and both the schema and the handler say so |

The `(a)` note, reproduced end to end on the base tree and on this one (same probe, three ways):

```
BASE   adopted bash {command='cat', stdin='hello', budget_ms=8000} -> {code:0, stdout:""}      silently dropped
BASE   bash {command='printf hi', stdinx='hello'}                 -> {code:0, stdout:"hi"}     no refusal
TIP    bash {command='cat', stdin='hello'}                        -> {code:0, stdout:"hello"}  one spawn path
TIP    adopted bash {command='cat', stdin='hello', ...}           -> {code:0, stdout:"hello"}  through adoption
TIP    bash {command='printf hi', stdinx='hello'}                 -> {error:"unknown_argument:stdinx", effect:"none"}
TIP+Lua on an OLD binary: adoption -> operation_unknown_field: stdin ... (refused BY NAME, not dropped)
```

The last line matters for a rolling fleet: a node whose binary predates the field refuses the call by name
instead of running it without the input.

## 2. One validator, at the one dispatch both routes share

`lua/core/tool_arguments.lua` (new) + one call site in `tools.dispatch`
(`lua/core/tools.lua`, after the role and retired-name checks, before anything runs) — commit `86399e56`.

* a key the tool's schema does not declare is refused as `unknown_argument:<name>[,<name>]`,
  `effect:"none"`, with `accepted` = the declared names in the fix line, so a retry can differ;
* it judges NAMES only (top level). Values stay the handler's business: a second opinion would be a second
  contract to keep in step;
* two allow-lists, each entry saying why it exists: `INTERNAL` (fields the RUNTIME adds —
  `budget_ms` from `adopt_bash`, `tool` from the reader label and the operation await,
  `image_bytes` from `lua/core/remote_image.lua`, `background` from code mode's start, the
  `file_path`/`old_string`/`new_string` synonyms from `file_tools.ALIASES`);
* a schema this node cannot read (`nil`) refuses NOTHING — unknown is not yes, and the tool's own path
  answers an unknown name;
* `WASM_AGENT_TOOL_ARGUMENTS=report` + `WASM_AGENT_TOOL_ARGUMENTS_LOG=<file>` records every would-be
  refusal and lets the call run, so a new refusal can be counted against real traffic.

Measured by `scripts/test-tool-arguments.lua` (34 checks, green): refusal by name, no effect, the declared
list, a declared field still accepted, the three synonyms, the runtime fields, a no-argument tool
(`nodes {probe=true}` → refused), a missing schema, an `additionalProperties:true` schema, and report mode.

### The ledger, measured as far as it is readable

The session ledger records the MODEL's own calls: over the 100 most recent sessions (the sessions tool's own
page limit; 1.3 days of the 5 asked) there are 143 of them, every one `run` (code mode), and none carries
an undeclared field. The inner `tools.<name>` calls a `run` block makes are executed by the code-mode
runtime and are NOT part of the transcript, so a full census of them cannot be read from the ledger — that
is a named limitation, not a pass. What stands in its place: the code census above (every entry naming the
code that writes the field) and the report mode, which makes the measurement possible on a real gate run.
The one common harmless spelling real calls carry is `file_path` (and `old_string`/`new_string`): the
handler already maps them, so they are allow-listed rather than broken.

## 3. Parity by construction

`adopt_bash` (`lua/core/server.lua`, `86399e56`) no longer re-picks three fields. It copies the caller's
arguments through the OPERATION START schema (`tools.parameters("operation")`), so a field added to `bash`
later travels without anyone remembering, and a field it cannot carry is refused
`peer_bash_field_not_adoptable` with the field named — never run without it.

`scripts/test-tool-args-parity.lua` (`3f5e7864`, 1048 checks, in the always-on whole-tree row list of
`scripts/lib/fast-rows.sh`): enumerates the whole catalogue (74 master tools), and for every declared field
of every tool asserts the peer path (`wa_peer_dispatch`, the seam a verified peer reaches) delivers it to
the executor unchanged, or refuses it by name with no effect (the one such case is the mesh's own
`operation.scope` node-scope rule). It then does the same for adopted bash, and carries a positive control:
with the operation schema asked without `stdin`, adopted bash with stdin must be refused.

## 4. bash {stdin}

`rust/wa-operation`: `Spec.stdin` (`lib.rs`), fed by the ONE spawn path (`process.rs`: a temp file the
child inherits and this process unlinks at once — a pipe would need a writer thread and would block the
supervisor past 64 KiB; `windows.rs` refuses by name, see "not verified"). `rust/wa-capabilities`:
`host.exec` takes a 5th argument, `operations::foreground` carries it, and `operation start` reads
`args["stdin"]` (added to `START_FIELDS`, whose own test parses the reads out of that function).
Lua: `bash` declares `stdin` (schema `maxLength` 1048576), the handler refuses `invalid_stdin` /
`stdin_too_large` (with `bytes`/`max_bytes`) before anything runs, and `tools.STDIN_MAX_BYTES` is the one
number. `scripts/test-bash-stdin.lua` (11 checks, green): hello through `cat`, a multi-line text, EOF after
one `read`, the null device when absent, the bound refusal (and the command never runs), the type refusal,
and the ADOPTED path a peer with `budget_ms` reaches.

### Found on the way: the refusal for an oversize argument never returned (fixed, `f0bb518a`)

The oversize refusal hung the node — and so did ANY refusal carrying a ~1 MB argument, and any large tool
result: `lua/core/redact.lua`'s `NAME=value` pattern is quadratic in the length of an unbroken token
(measured: 10 KB 0.40 s, 20 KB 1.66 s, 40 KB 6.74 s — four times the work for twice the text, so 1 MB was
hours). Fixed without weakening masking: a gate that skips the scan when no marker word is present (exact by
the pattern's own requirement), and one window per marker word instead of one scan over the whole text.
1 MB with a real `KEY=...` pair: 0.031 s, same answers; `scripts/test-redact-secrets.lua` (23 checks) and
`scripts/test-secret-guard.lua` (36 checks) unchanged and green.

## 5. grep {context}

`rust/wa-capabilities/src/file_search.rs` (`86399e56`): `context` 0-10, default 0 (no window is read and no
key appears, so today's answers are byte-identical — the row compares the default answer to an explicit
`context=0` byte for byte), `before`/`after` arrays on each match with the same 400-character clip and
`line_chars`, MERGED ranges (a line two windows share appears once, in the earlier match's `after`), a
window at the edge of the file stops at the edge, and the answer says which window it used. Lua: `context`
declared, range-checked (0-10, integer) and passed through in the `host.grep` options.
`scripts/test-grep-context.lua` (`3f5e7864`, 14 checks, green).

## 6. What the model reads: exact bytes

`scripts/probe-prompt-bytes.lua`, base `c1337903` vs tip, same binary:

```
                     base        tip
prompt_bytes         21409       21409     (0 bytes: the cached prompt prefix does not change)
system_bytes         20623       20623
envelope_bytes       786         786       (progressive envelope: one tool, `run`)
catalogue            74 / 23     74 / 23   (master / guest declared tools)
```

The tool catalogue text is NOT in the cached prefix under the progressive envelope: the whole change reaches
the model only through `searchTools`/`describeTool` answers and through the generated
`docs/ENVELOPE.md` (regenerated by `scripts/sync-prompt-docs.sh --write`, its table rows are in the commit).
Measured growth of what a `select:` answer carries:

| tool | description bytes | schema bytes | fields added |
|---|---|---|---|
| bash | 305 → 363 (+58) | 346 → 537 (+191) | `stdin` |
| grep | 248 → 333 (+85) | 306 → 589 (+283) | `context`, `node` |
| read | 514 → 514 (0) | 239 → 360 (+121) | `node` |
| write | 170 → 254 (+84) | 115 → 237 (+122) | `node` |
| edit | 584 → 620 (+36) | 1081 → 1249 (+168) | `node` |
| ls | 62 → 103 (+41) | 57 → 183 (+126) | `node` |
| operation | 652 → 652 (0) | 1224 → 1353 (+129) | `stdin` |

## 7. node= on read/ls/grep/write/edit

`lua/core/tools.lua` (`86399e56`): the five route through the SAME call `remote` makes
(`M.dispatch(… "remote", {node, capability, args})`), so a local call and a peer call cannot drift; a name
that is THIS node runs the call here with this session's context; a call that arrived from a peer is refused
`node_not_forwarded` (a node is never a relay), and history keeps its own `history_node_not_forwarded`.
Every answer names the node the bytes landed on (`on_this_node` here, the peer's own `node` there).
`scripts/test-file-tool-node.lua` (`3f5e7864`, 36 checks, green) drives all five through a recorded
transport seam, plus the local case, the peer-call refusal, and the schema.

## 8. Texts to approve (verbatim, from the diff)

Schema descriptions, the clause each one gains:

1. `bash`: "… For deliberate long-lived work use operation start." → "… **stdin is the text the command
   reads and then sees closed.** For deliberate long-lived work use operation start."
2. `bash` property: `stdin`: "Text fed to the command's standard input, then closed. It is delivered as
   the command's input, not pasted into the command line."
3. `operation` property: `stdin`: "start only: text fed to the command's standard input, then closed."
4. `grep`: "… extensions are exact suffixes without dots." → "… **context returns the lines around each
   match; node=<peer> searches that peer's files.**"
5. `grep` properties: `context`: "Lines of context before and after each match; 0, the default, returns the
   matches alone."; `node`: "Peer name or node_id (from nodes): search that node's files instead of this
   one's."
6. `read` property: `node`: "Peer name or node_id (from nodes): read that node's file instead of this
   one's."
7. `write`: gains "**node=<peer> writes that peer's file; the result names the node the bytes landed
   on.**" and the property "Peer name or node_id (from nodes): write that node's file instead of this one's."
8. `edit`: gains "**node=<peer> edits that peer's file.**" and the property "Peer name or node_id (from
   nodes): edit that node's file instead of this one's; the result names the node the bytes landed on."
9. `ls`: "List a directory (portable: works the same on every platform)." → "… **node=<peer> lists that
   peer's directory.**" and the property "Peer name or node_id (from nodes): list that node's directory
   instead of this one's."

Refusal sentences a model reads:

* `unknown_argument:<names>` — "`<tool>` declares: <names>. Nothing ran: an argument the tool does not
  declare is refused by name rather than ignored, because a dropped field is a call that did something else
  in silence. Send the declared names only."
* `stdin_too_large` — carries `bytes` and `max_bytes` (1048576); `invalid_stdin` for a non-text value.
* `node_not_forwarded` — "This call already arrived from another node, so it is answered on this one or
  refused; it is never forwarded again. Name the peer in a call made on the node you are talking from."
* `peer_bash_field_not_adoptable` — "this node's adoption path (budget_ms) cannot carry `<field>` into the
  supervised operation, so the call is refused rather than run without it; send the same call without
  budget_ms, or declare the field on the operation tool's own schema."

## 9. Proposed FACTORY.md / HANDOVER.md text (proposed, not written)

FACTORY.md, beside the tool-contract rules:

> **A tool argument is judged once.** Every route a call can take - a model's direct call, a script's
> `tools.<name>`, a `tool_call` batch, a peer's capability - reaches `tools.dispatch`, and there
> `lua/core/tool_arguments.lua` refuses a field the tool's schema does not declare, by name, with
> `effect:"none"`. Adding a field to a tool therefore means adding it to the schema and nowhere else; a
> field the runtime stamps on its own calls goes in that module's `INTERNAL` table with the code that
> writes it. When work is started by a second implementation (`adopt_bash` -> `operation start`), the
> second one forwards the caller's arguments BY SCHEMA and refuses what it cannot carry;
> `scripts/test-tool-args-parity.lua` is the row that goes red when it stops doing that.

HANDOVER.md, "what a new session should know":

> Tool arguments are honest: an undeclared field is refused by name (`unknown_argument:<field>`) at
> `tools.dispatch`, on every route, local and peer alike. `bash {stdin}` and `grep {context}` exist on
> both. `read/ls/grep/write/edit {node}` route through `remote`. To measure before adding a refusal, run
> with `WASM_AGENT_TOOL_ARGUMENTS=report` and `WASM_AGENT_TOOL_ARGUMENTS_LOG=<file>`.

## 10. What I could not verify (and did not do)

* **A real peer.** No live fleet was touched (mission rule). "On the peer" is proven here by the capability
  call the transport seam recorded, never by a different disk.
* **Windows stdin.** `process.rs` feeds it from a file; the Windows spawn builds its own pipes and now
  REFUSES by name (`stdin_unsupported_on_this_platform`) instead of dropping the text. Not built or run on
  Windows by me.
* **The full gate.** Per the mission's suite rule I ran only the rows for what I touched, plus the new rows
  singly (below). `scripts/test-discriminates.sh` (base discrimination) and `main-health` were not run.
* **The inner-call census** of the ledger, for the reason in section 2.
* `rust/wa-capabilities` unit tests: 394 pass with the suite's own environment
  (`HOME=GATE_ROOT=GATE_HOME=<scratch>`); `host::tls_anchor_tests::a_provider_call_refuses_a_private_ca_that_no_bundle_names`
  fails offline on this node (`Timeout(Connect)` where it expects a TLS refusal) and is unrelated to this
  branch — it needs a network path this node does not have.

## 11. State of the rows (measured, this branch)

Run singly against the tree's own binary (`WASM_AGENT_LUA_ROOT=<wt>`, scratch home):

| row | result |
|---|---|
| `scripts/test-tool-arguments.lua` | ok, 39 checks |
| `scripts/test-tool-args-parity.lua` | ok, 1048 checks |
| `scripts/test-bash-stdin.lua` | ok, 11 checks |
| `scripts/test-grep-context.lua` | ok, 14 checks |
| `scripts/test-file-tool-node.lua` | ok, 36 checks |
| `scripts/test-redact-secrets.lua` | ok, 23 checks |
| `scripts/test-secret-guard.lua` | ok, 36 checks |
| `scripts/test-edit-aliases.lua` | ok, 35 checks (one assertion updated, below) |
| `scripts/test-federation.lua` | ok, 49 checks |
| `scripts/test-remote-edit.lua` | ok, 46 checks |
| **`scripts/test-remote-pending.lua`** | **RED — open blocker, see below** |
| `rust wa-capabilities` unit tests | 392 passed, 1 failed: `host::tls_anchor_tests::...` (offline node; pre-existing) |

### The one open blocker

`scripts/test-remote-pending.lua` fails at "wait(op) resumes it" with

```
{"op":"op-…","progress":{"reason":"unknown_argument:capability,node","state":"unknown"},"state":"pending","tool":"remote"}
```

i.e. somewhere in the code-mode pending path (`lua/core/codemode_pending.lua`, the `remote` executor) a call
reaches a tool with only `{capability, node}` and the validator refuses it. What I ruled out: the same call
through `tools.dispatch(memory,'remote',{node=…,capability='operation'},…)` is ACCEPTED and answered
`unknown_node:peer` (the node does not exist), because `remote` now declares `additionalProperties: true`
(measured with `probe`). So the refusal is a *different* dispatch than the one the executor builds at its
top level, and I did not finish locating it before the session's budget ran out. It must be found and fixed
before this branch lands — the mission's own rule is that a red row does not ship.

### The one assertion I changed, and why (not loosened)

`scripts/test-edit-aliases.lua` #6 sent a typo (`old_txt`) and expected the handler's private code
`unsupported_edit_option`; the validator now refuses it first, so the assertion expects
`unknown_argument:old_txt` plus `effect:"none"`, and the "first line names the accepted arguments" check
now looks for names the SCHEMA declares (`edits`, `range_edits`) instead of a synonym (`file_path`) that
was never in the schema — the same section 1 of that row proves the synonyms still work. Nothing was
deleted: two checks became one named code plus `effect`, and the first-line check stayed as strict about
which names it wants.

### Fields real call sites send that the schemas did not declare (found by the rows, all fixed)

* `operation`: the pending layer sends `output` and `max_bytes`; the kernel sends `control` — added to
  the validator's `INTERNAL` table with the code that writes each;
* `remote`: the schema never declared the capability's own parameters (`cwd`, `offset`, `edits`,
  `content`…) although its description tells the model to send them flat — it now declares
  `additionalProperties: true`, and `schema()` grew the optional fifth argument that lets a tool say so;
* `edit`: the synonym TARGETS `old_text`/`new_text` are accepted at the top level (the alias maps
  `old_string` onto `old_text`), so they are allow-listed beside the synonyms.

