# remote-edit-first-class: a remote edit is the edit you know here

Base main `c6f890e3`. Branch `change/remote-edit-first-class` in
`/home/victor/Work/missions/remote-edit-first-class/wt`, two commits:

- `b12862ad` - remote edit on a peer: the fence is the session's, the change is recorded here, undo
  restores it there.
- `e2caf839` - remote edit: the description shows the edit example the brief names.

Every claim below cites one of those, or a measurement whose command is in this file.

## 1. Measured first, before any code (and where the brief was wrong)

Confirmed as read:

- `lua/core/server.lua:1729` `local MANAGED_CAPABILITIES = { status=true, set_role=true, read=true,
  write=true, edit=true, ls=true, grep=true, bash=true, ... }` - a peer serves edit and write.
- `lua/core/tools.lua:559` the `remote` schema: its examples were `bash` and `read`, and the
  `capability` property said `e.g. bash, read, client, shell`. An edit on a peer was never named.

**Premise (a) was wrong: the fence already fired across nodes.** `wa_peer_dispatch` passes
`session_id = "peer:<caller node id>"` to the tools (server.lua:1554 before this change), so a read
through a peer records a page in the PEER's `file_tools` table, and an edit whose anchor is outside it
is refused with `edit_anchor_outside_read_page`. Measured in a two-node fixture against the real
`wa_peer_dispatch` (scratch home, 3000-line file): read offset=1 limit=10, then edit `line 2000` ->
`{"error":"edit_anchor_outside_read_page"}`.

What was actually broken is narrower and worse:

1. the record used is the PEER's, keyed by the caller NODE - every session on that master shares it, so
   a session that read nothing is refused an anchor it never quoted (a false refusal, the guard
   claiming a page nobody was given), and a second caller id inherits the first one's page record;
2. the record dies with the peer's process, so the fence silently disappears on a peer restart.

Raw measurements (base `c6f890e3`, `WASM_AGENT_HOME` scratch, `WA_SCRIPT` a scratch probe):

    read: truncated=true version=4588... range={"first_byte":1,"first_line":1,"last_byte":71,"last_line":10}
    edit, anchor never read, same caller: {"error":"edit_anchor_outside_read_page"}
    edit by a DIFFERENT caller node: {"applied":true}

**Premise (b) was right.** `wa_peer_dispatch` passed no `changes` in its context, so
`changeset.record` never ran on either side: a remote edit left no change record anywhere, so no undo
and nothing for the diff card. The same fixture on the base leaves `ctx.changes` empty.

Not re-measured, and said so here: the ledger counts in the brief (53 model messages ran `python3`
through `tools.remote`, 35 mentioned a remote edit, last 3 days). The node's own store is fenced for
agent tools - `sqlite3 ~/.wasm-agent/memory.db` is refused with `secret_path_denied`
(lua/core/secret_guard.lua) - so those numbers stand as the brief's, not as mine. Also not run: a live
`avell -> nextcloud` call (mission rule 13, and the 19/11 relay storm). Both premises above come from
the two-node fixture against the real dispatch instead, which is the cheapest check that could fail.

## 2. What the change is

One rule: the node that holds the SESSION owns what it was shown, and the node that holds the FILE
answers what it holds. The caller states the first in the signed body of the call; the peer applies
it; the peer answers the second in the same answer.

- **The page record travels, and it is the caller's.** `file_tools.page_snapshot` / `record_peer_page`
  (file_tools.lua:257,277) keep (session, node, path) - the key now names the node, so the same path on
  two nodes is two records. `remote` records the page its own `read` answer served (tools.lua:2337).
  The record goes in the SIGNED BODY as `read_pages` (nodes.lua:1651 `remote_call(..., options)`),
  never in `args`: `args` is what the model writes, and a fence the model can set is not a fence.
  server.lua:1594 hands it to the tools as `ctx.read_pages`; `edit` uses it in place of its own record
  (file_tools.lua:624) with the same refusal code, range and note as a local edit.
- **`record = false` is a fact only the caller's process holds**: "this session was served nothing for
  that file on that node". It is why a second session is no longer fenced by the first one's page.
  A record the peer cannot read is refused by name (`edit_read_page_invalid`) - unknown is not yes, and
  "no record" is the one reading that turns the fence off.
- **The change text travels back only when asked** (`record_change` in the same body). The peer attaches
  `result.change = {path, before, after}` from the plan it just applied (file_tools.lua:624,
  tools.lua `change_for_wire`), bounded by `changeset.RECORD_CAP` (262144, now exported) - a text past
  the cap is not sent at all, and the row says why. The caller records it in ITS OWN changeset with the
  node it happened on (tools.lua:2337 region), then drops `change` from the answer so the model is not
  handed the whole file twice.
- **The change record says where the file lives.** `changeset.record(entry, path, before, after, node,
  reason)` (changeset.lua:356) keys a file by (path, node); `summary`, `normalize` and `wa_diff` carry
  `node`; `check`/`undo`/`redo`/`apply_all` write through `set_file_host` (changeset.lua:117) instead of
  `host` when the file names a node. server.lua:46 installs that host: the peer's `read` capability for
  the guard (its `version` is the whole file's digest even for a one-line page, so a 200 KB file is
  verified without moving it) and its `write` capability for the restore. Nothing is loosened: the only
  caller is this node's own `/diff` route, which requires a master, and the peer applies its own write
  capability with its own guards.
- **One honest row for an older peer**: no `change` in the answer -> `changeset.record(..., before=false,
  reason="peer_sent_no_change_text")`, so the change record holds one row that cannot be undone and
  says why. `check` reports `peer_sent_no_change_text:<path>`, never a crash.
- **A call addressed to this node** (`remote` with this node's own name) now runs under this session for
  read/write/edit (tools.lua:2290 region), so a self-addressed edit is no longer the one edit on this
  machine with no fence and no record.

## 3. Item by item

1. **Same safety as a local edit.** Exactly-once match, nearest region on a miss, atomic multi-edit,
   `file_changed_before_write` - all unchanged, because a remote edit runs the LOCAL `file_tools.edit`
   on the peer. The fence is now judged by what THIS session read on THAT node (commit `b12862ad`,
   file_tools.lua:257-330 and 624, server.lua:1413/1561/1594, tools.lua:2290-2370, nodes.lua:1651).
2. **The change is recorded here, and undo works from here** (`b12862ad`: changeset.lua:117-200, 356,
   420-470; server.lua:46 and 2132; tools.lua:996,1014,2337).
3. **The description names it** (`e2caf839`). Measured byte delta, `tools.catalog('master')` encoded as
   the prompt prefix: **73190 -> 73547 (+357) bytes**, of which the `remote` description itself is
   **679 -> 1014 (+335)** and the remaining +22 are the JSON escaping of the eleven quote pairs in the
   example. It moves the prefix once, at the next release.
4. **Both ends must be updated** - the matrix is in section 4.

## 4. Old caller, new peer; new caller, old peer

| caller | peer | what happens |
|---|---|---|
| new | new | the fence is this session's record; the change is recorded here; /undo restores it on the peer |
| new | old | the peer ignores the two fields it does not know (it verifies the signature over the body as BYTES, so an extra field cannot fail its check) and applies the edit exactly as today. No fence from this session's record, no change text: this node records one row with reason `peer_sent_no_change_text`, and /undo refuses it by that name. Nothing that worked before refuses. |
| old | new | no `read_pages` -> the peer falls back to its own record for that caller node, which is exactly the old behaviour (no loosening); no `record_change` -> no texts sent, so an old caller's session still records nothing, as today. |
| old | old | unchanged. |

So the safety and the undo need the peer updated; the cost of not updating is the row that says so.

## 5. Tests

`scripts/test-remote-edit.lua` - 43 checks, the two-node fixture (the peer half is the real
`wa_peer_dispatch`; the caller half is the real `tools.remote` handler; what stands between them is
`nodes.remote_call`, the seam `tools.remote` itself uses, carrying what the signed body carries).
It pins: a second session on the same caller node is not fenced by the first one's page; the reading
session IS refused outside its page, with the page named in the refusal; the page record this session
was served on that node (and not on another); the change recorded here with both texts and the node;
undo through the real `wa_diff` route restoring the file on the peer with a `write` capability call
carrying the previous text, and redo; the same for a remote write; an older peer's one honest row and
its named undo refusal; a page record the peer cannot read refused by name with nothing written; the
signed body carrying both fields outside `args`; and the description holding the example.

- Hermetic: it refuses to run unless `WASM_AGENT_HOME` is a scratch/temp directory and not
  `~/.wasm-agent`, `host.http` throws, and it never calls the live fleet.
- Wired: `scripts/fast.sh` runs every `scripts/test-*.lua` not listed in `scripts/fast-path.exclude`
  (mine is not listed), and `scripts/test.sh` reaches the same set through
  `scripts/test-core-parity.sh`, which runs the fast-path Lua set twice (native and in the guest).
- Discrimination, from the land gate's own script (`WA_BIN=~/.local/bin/wa bash
  scripts/test-discriminates.sh c6f890e3`): `discriminates	scripts/test-remote-edit.lua` - it fails on
  the base at "a session that read nothing is not fenced by another session's page:
  {"error":"edit_anchor_outside_read_page"}", i.e. on the false refusal measured in section 1, not on
  a missing symbol.

`scripts/test-node-dispatch-wiring.lua` is modified: its dispatch-region anchor matched
`local function node_capability(capability, args, caller)` including the closing paren, and the
signature gained the decoded request. The anchor now stops at the parameter list; every assertion is
unchanged, and the gate records it as `unchanged-verdict` (it passes on both trees).

Regression set run here, each with its own scratch home: test-changeset (40), test-diff-route,
test-read-truncation (69), test-remote-pending (90), test-remote-call-shape (87),
test-node-dispatch-wiring (10), test-codemode-boundary, test-refusal-contract (17152),
test-session-isolation (141).

Pre-existing failure, named not mine: `scripts/test-remote-refusals.lua` fails at line 18 ("node
refusal through the relay") on the base `c6f890e3` too - measured by running it in a base worktree.

## 6. Texts to approve (model- and operator-facing, verbatim)

1. `tools.remote` description - the two appended excerpts (the rest of the description is unchanged):

   `... or {"node":"<name>","capability":"edit","path":"...","edits":[{"old_text":"...","new_text":"..."}]}: an edit there is the edit you know here - exactly-once match, the nearest region on a miss, the read-before-edit fence judged by what this session read on that node - and the change is recorded here, so /undo restores that file there. Text reads work; ...`

2. Refusal `edit_read_page_invalid` (new, `lua/core/refusal.lua`, shown only when it happens):

   message: `the page record this call carried for the file on that node could not be read, so whether the anchor was ever shown to this session is unknown ({origin}).`
   fix: `nothing was changed. That record is written by the node holding the session, never by hand: if this repeats, that node and this one are on different versions - check \`nodes\` and update the older one.`

3. Undo/topic reasons (operator-facing, `changeset.check` through `/diff check|undo`):
   `peer_sent_no_change_text:<path>` (new), `change_not_recorded:<path>`, `text_unavailable:<path>`,
   `larger_than_record_cap:<path>` (the last three are the reason a peer could not send the texts).
   Unchanged: `too_large_to_undo:<path>`, `changed_since_turn:<path>`, `missing_since_turn:<path>`.

No other model-read text changed. The `capability` property still says `e.g. bash, read, client,
shell` - the brief allowed one text, and this is that one.

## 7. For script-writes-show-diff (the card), from the data side

`message.changes.files[]` now carries, per file: `path`, `added`, `removed`, `created`, `before`,
`after`, `recorded`, and (new, only when they apply) `node` - the peer's name the change happened on -
and `reason` - why it cannot be undone. The `before`/`after` are still digests into THIS node's
content-addressed store, so the card's existing blob reads work unchanged; a remote file needs the
`node` beside the path to be honest about where it lives. I did not touch `lua/core/diff_view.lua`.

## 8. What I did not verify

- No live `avell -> nextcloud` call, and no live fleet at all (rule 13).
- The relay and the peer's signature check between two real machines: the fixture replaces the
  transport. Those are covered by `scripts/test-remote-refusals.lua` (pre-existing failure above),
  `scripts/test-mesh-*.lua` and `scripts/test-remote-pending.lua`.
- Two machines: in the fixture, "the peer's file" is this filesystem. That the restore happened ON the
  peer is proven by the capability call the stand-in recorded, never by a different disk.
- A peer whose file is above the read budget is untouched here: the guard reads only the digest, so
  size is not a limit for undo, but that path has no dedicated test beyond the digest one.
- The relative-path edge: the page record is keyed by the path AS THE MODEL WROTE IT, so `read
  demo.txt` then `edit /abs/demo.txt` on the same peer does not find the record and is not fenced -
  the same fail-open as a session that never read. Absolute paths (what the remote surface uses in
  practice) are exact.
