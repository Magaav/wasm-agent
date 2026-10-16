---
name: codemode-output
description: Present native code-mode reads or edit receipts without double JSON escaping; recover partial output and cached read_many pages, or reread after a formatter/stale-edit refusal. Use when aggregate native output is large or receipts are noisy, not for trivial calls.
---

# Native output and fresh receipts

Load `docs/CODEMODE.md` (Structured native presentation) for the versioned contract.
This is opt-in presentation, not a smaller global output budget or a new cache.

```js
await tools.read_many({requests:[{path:'docs/A.md',limit:120},{path:'docs/B.md',limit:120}]});
await showCall({version:1,call:1});
```

`call` is the one-based admitted native-tool call index, not a discovery/helper
attempt ID. `await describeTool('showCall')` gives the helper contract. Do not also
`text`/return the same large result: that adds escaped copies. Small counters or
explicitly selected diagnostics remain suitable for `text`.

Inspect `shown`, `presentation_sanitized`, `presentation_redacted`, per-item errors,
EOF/byte continuations and cached `next_cursor`. Displayed content is a normal
redacted model view, not byte-identical private evidence. Original source byte counts
and selections remain tied to the captured original. Never form old_text from masked
source. JSON-key redaction collisions refuse visibly, not complete empty success.
A visible captured page is not necessarily a whole document or whole batch.
Continue later cached results with ordinary `read_many({cursor:...})`; do not rerun
the script, particularly effects. If `presentation_partial`, inspect all unread
coverage before claiming review complete. Each unread range names the native
original SHA-256, exact offset and byte count. Retrieve with `tool_result`, following
its bounded `next_offset` until the range is covered. This boundary fallback costs
extra retrievals; retained bytes are not model awareness. No automatic pagination,
refetch, retry, arbitrary formatter inference or rollback occurs.

After a formatter or stale-edit refusal, explicitly reread current source, then
form a NEW exact edit from that source/selection. Do not alter old_text by guessing
or reuse the stale selection. A fresh receipt is a new snapshot, not recovery of
the old captured source. Keep successful earlier effects and unknown outcomes
visible; never replay the earlier script to obtain its output or fresh receipts.

```js
const current = await tools.read({path:'src/example.lua',offset:20,limit:12});
// Inspect current.content before constructing the next exact edit.
await showCall({version:1,call:1});
```

Then use ordinary `edit` with that exact current selection and explicit inclusive
line frame, or a uniquely occurring old_text copied from the current read. Separate
interpretation-dependent steps rather than inventing a mutating retry helper.
