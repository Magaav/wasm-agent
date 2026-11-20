# read-truncation

Branch `change/read-truncation`, base `origin/main` = `39bbf2b6` (land 2b), worktree
`/home/victor/Work/missions/read-truncation/wt`. Two commits, one per item.

## Measured problem (re-measured before writing code)

The premise in the brief held: `tools.read` returned a page with `bytes`, `returned_bytes`,
`total_lines`, `next_offset`, `range_complete` and `eof`, and **no field comparing what it returned
to the size of the file**. Reading `lua/core/file_tools.lua` (523 lines at the base) confirmed it:
the envelope at `file_tools.lua:184-196` was the whole of the answer, and every field was about the
cursor, never about the file behind it. A page of 4 KB out of 186 KB printed `range_complete: true`
(a whole-line page) and nothing that a caller could read as "this is not the file".

A second premise also held, and set the shape of item 2: the file itself cannot say which bytes a
caller was shown. The fence therefore records the pages the session was served, instead of trying to
infer a partial view from the file.

Two premises needed correcting:

* The brief says the fence must refuse an anchor outside the returned range. A pure range check
  refuses legitimate edits: after the first applied edit the version changes, and every later edit
  in the same run would be judged against a stale page. The committed rule is version-scoped
  (item 2 below) and an allow-list, per rule 7.
* The brief's "fence-card notes" mission wrote outside this tree, so the exact files are not
  re-measurable here; the 19-20/11 failure mode is taken from the brief and was reproduced as a
  test (an anchor quoted from a 5-line page of a 400-line file), not from those mission logs.

## Item 1 - every read page says what it returned and what it did not (7ab36fda)

`git show 7ab36fda -- lua/core/file_tools.lua lua/core/tools.lua`.

Every text page now carries, in addition to the fields it already had:

* `file_size` (and `bytes` kept equal to it, so nothing that read `bytes` breaks),
* `bytes_read` (and `returned_bytes` kept equal to it),
* `range = {first_byte, last_byte, first_line, last_line}` - the range this page returned,
* `truncated` - **always present, always a boolean**, so a caller never has to tell "whole file"
  from "a node too old to say",
* when truncated, `truncation = {reason, bytes_read, file_size, first_byte, last_byte, first_line,
  last_line, lines_in_file, missing_before, missing_after}` and, when something follows,
  `truncation.next` = the exact call (`path`, `offset`, `column`, `version`) that continues,
* `how_to_read_rest` - one sentence naming the byte range returned, the file size, the line count
  and the way on.

A page that **starts** after byte 1 is truncated too, and says `missing_before`, offers no
`truncation.next` and points back at offset 1 instead of at a dead cursor. A page cut by the
per-call byte budget says so (`reason` names the budget), where a page cut by the requested lines
says that instead.

The `read` schema text (`lua/core/tools.lua:446`) names the new fields - that string is item 1 of
"Texts to approve".

## Item 2 - an anchor from a partial page is refused by name (39a28c88)

`git show 39a28c88 -- lua/core/file_tools.lua lua/core/refusal.lua lua/core/tools.lua`.

A read records, per session scope and path, the byte ranges it actually served at one version
(`record_page`, bounded to 64 files x 16 ranges). At edit time, if this session's record for the
file is at the same version and is not a whole-file read, an anchor whose **first or last byte** lies
outside every served range is refused:

```
edit_anchor_outside_read_page
```

with `anchor_byte`, `anchor_line`, the `pages` the session actually had, and a `note` naming the
way on. Allow-list, not a block-list (rule 7):

* a **whole-file read at the same version** sets `whole` and permits every anchor - the fence can
  never refuse a caller who was given every byte;
* **no record at this version is not a refusal**: nothing was promised, so nothing is refused;
* a **newer read** starts the record over, so an old page cannot allow an anchor this file no
  longer has.

The anchor must be covered **end to end**, not just at its two ends (`covered_pages`, review r1
SHOULD 2): two served pages with an unserved gap between them used to let a spanning anchor through.

Review r1 MUST 1, fixed in `8911ab42`: `record_page` first ran inside `envelope()`, which the
shrink loop calls again for every smaller capacity, so pages the caller never saw were recorded -
and a file whose raw bytes fit but whose JSON-escaped form does not recorded a whole-file page
first and turned the fence off. The record now happens once, after the loop, from the range the
returned page actually carries; a refused read records nothing.

The scope is passed by `tools.dispatch` (`ctx.session_id`) for both `read` and `edit`. A direct
module call with no scope records nothing and is never fenced, which is what keeps the batch
(`tool_call.calls`) path unchanged.

**Where the record lives, and what that costs** (review r1 SHOULD 4): the page table is an
in-process table in `lua/core/file_tools.lua`, so it belongs to one `tools.lua` instance and is
**shared by every session in that instance** - not per session in storage. It is bounded hard: 64
files (least recently recorded evicted first) x 16 ranges per file, and the eviction order is
global, so one busy session can evict another's page. Every one of those limits **fails open**: an
evicted page, a restarted node, or a scope with no record means no refusal, never a wrong refusal.
The fence is a guard against a partial view that is still in hand, not an audit of everything a
session ever read.

## Tests (rule 16: each fails on the base)

`scripts/test-read-truncation.lua` - 68 checks after review r1, wired **into the fast path by
default**: it is not
listed in `scripts/fast-path.exclude`, so `scripts/fast.sh` runs it as a `scripts/test-*.lua` row
with its own scratch `WASM_AGENT_HOME`. Every read and edit goes through a **real code-mode run
block** (`tools.dispatch(memory,'codemode',...)`), the path real use takes (rule 14), so the new
fields have to survive the envelope the model actually reads. The row refuses to run on the
operator's home.

On the base worktree (`git worktree add --detach /tmp/base-read-trunc 39bbf2b6`, the row copied in,
its own scratch home, the tree's `wa`):

```
39bbf2b6 land 2b: merge change/tui-polish-3
lua error: [string "scripts/test-read-truncation.lua"]:27: the page reports the file size: nil
```

That single failure covers both items (the run stops at the first item 1 assertion; item 2's cases
are further down the same row and cannot pass while the page carries no truncation record at all).

## Pre-existing reds (proven on the base, not caused by this branch)

* `scripts/test-refusal-contract.lua` fails on `39bbf2b6` exactly as it did before this branch:
  `lua/core/refusal_codes.lua is stale`. `lua5.4 scripts/gen-refusal-codes.lua --check` exits 1 in
  the base worktree, before any change of mine. The map was **already** missing
  `cancel_not_confirmed` (codemode_pending.lua); regenerating it here adds that entry plus this
  branch's `edit_anchor_outside_read_page`. This branch therefore leaves the check green, and does
  not own the drift.

## Fast path

Supervised operation op-1795171932118072-28317-4 under the shared suite lock
(flock /home/victor/Work/missions/.suite.lock), log
/home/victor/Work/missions/read-truncation/fast.log, tree 3be51c04 on change/read-truncation,
tree binary sha256 8e6e0cd0.

    fast: lua 257/257 passed (58 excluded: scripts/fast-path.exclude)
    fast: 1 named skip(s) inside passing rows (a skip is not a pass):
    fast:   scripts/test-cli-view.lua: 1 skip(s), first: reserve agreement: no WASM_AGENT_MODEL_LIMITS fixture (test.sh runs this file again with one)
    fast: rust - no crate touched
    fast path ok (303 checks, 0 skipped, 280s)
    FAST_EXIT=0

scripts/test-read-truncation.lua is named in the run's own result JSON. The single skip is in
scripts/test-cli-view.lua and is a missing fixture in that row, not this branch; nothing on this
branch was skipped. No FAIL row.

The pre-existing red recorded above (scripts/test-refusal-contract.lua) does not reappear: this
branch regenerated lua/core/refusal_codes.lua, which is what that row checks, so the row is green
here while the base 39bbf2b6 still fails its --check.

## Texts to approve (model- or operator-facing strings)

1. `read` schema description (`lua/core/tools.lua:446`), new sentences:
   "Every text page reports bytes_read against file_size plus its line range and total_lines, and
   sets truncated with the range it returned and how to read the rest whenever it did not return
   the whole file; a whole file says truncated: false."
2. `edit` schema description (`lua/core/tools.lua`, `edits` form), new sentence:
   "An anchor that lies outside every byte range this session read from that file is refused by
   name (`edit_anchor_outside_read_page`): read the page that holds it."
3. Page `note`, appended when truncated - `how_to_read_rest`:
   "returned bytes <first>-<last> of <size> in <lines> lines; more follows: call read with
   truncation.next and follow next_offset until eof." (or, for a page that starts late: "earlier
   lines were not returned: start again at offset 1, column 1.")
4. `truncation.reason` values: "this page reached the per-call byte budget", "the requested lines
   ended before the last line of the file", "the read started after the first byte of the file".
5. Refusal `edit_anchor_outside_read_page` (`lua/core/refusal.lua`):
   message: "this session read only part of this file, and the anchor is outside every byte range
   that read returned, so it was quoted from a page nobody was given ({origin})."
   fix: "read the page that holds the anchor (read with offset/column, or the truncation.next the
   partial page named) and quote the bytes from it; a whole-file read of the same version clears
   this."
6. The refusal's own `note` on the result:
   "this session read only part of this file: the anchor is outside every byte range read returned.
   Read the page that holds it (read with offset/column, or truncation.next) and quote the bytes
   from that page; a whole-file read of the same version clears this."
