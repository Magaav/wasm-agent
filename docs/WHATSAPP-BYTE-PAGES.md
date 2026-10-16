# WhatsApp byte-bounded pages and exact fields (page contract v2)

This corrects the remaining count-only read defect against9be5376e. It changes only
read construction/transport, not pairing, scope grants, posting, gaps or legacy cleanup.
No activation/live-account acceptance is implied.

## Wire contract

- `read_snapshot`, `list_chats`, `posting_status` have a fixed **4MiB encoded UTF-8
  JSON response budget including the final LF**, plus the existing total row limit
  (default2000, maximum10000). `encoded_bytes` is the actual HTTP body size;
  `byte_limit` is4194304. This leaves room below24MiB MCP stdio/native transport
  limits for both structured content and escaped text-envelope duplication.
- `page_version:2` is explicit. Numeric row-ID `before`/`next_before` and
  `cursor_version:1` retain their meaning: a scoped live keyset window, **NOT a pinned
  snapshot, signed artifact cursor or cryptographic scope fence**. Authorization
  is independently rechecked on EVERY page and field request. Row updates may be
  visible between pages. New higher-ID inserts do not enter an older continuation.
- `order` lists every delivered primary row outcome in descending cursor order,
  as `{cursor,kind,index}`. Inline indices refer to messages/conversations/posts for
  that resource; oversized indices refer to `oversized_rows`. Derived conversation
  summaries on message pages are not additional primary outcomes.
- `rows_delivered` counts outcomes, including explicit oversized references.
  `inline_rows_delivered` counts inline content. `inline_complete:false` means some
  delivered outcomes require exact field retrieval; it is not empty/missing content.
- `truncated`, `byte_truncated`, `row_truncated` distinguish why iteration stopped.
  On continuation, `next_before` is the LAST DELIVERED OUTCOME cursor. A candidate
  that would exceed remaining bytes is NOT appended, skipped, clipped or consumed;
  it remains eligible on the next page. `next_before:0` means no more row outcomes
  in this window, not that oversized source content was already downloaded.
- A first normal row always fits the production budget. A single oversized or
  non-inline-representable row produces a bounded reference, not a starvation loop.
  An impossible envelope/no-progress condition fails with a small503
  `page_no_progress` response, no content and no cursor advancement.

## Exact source retrieval

Each oversized reference contains resource, row/cursor and field metadata:
`byte_length`, `sqlite_type`, `field_version`. No giant preview or truncated body is
substituted. Normal inline strings must be valid UTF-8; other bytes are referenced.
Only whitelisted projected message/chat/post fields are readable—never raw media
protobuf, device keys, authentication tables, config or arbitrary SQL.

Use `read_field {resource,row,field,version,offset,length}` through the same locally
approved MCP binding. Default/max raw chunk length is16384 bytes. Responses use
`content_encoding:base64`, `data_base64`, exact byte/offset/next_offset and complete
metadata. Base64 preserves UTF-8 sequences even when a boundary splits a character,
control characters, invalid UTF-8 and escaping exactly. Decode/concatenate bytes,
then decode text only once the field is complete. `sqlite_type` preserves the
projection's type; bytes are SQLite CAST(field AS BLOB), not an arbitrary DB dump.

Field versions are optimistic counters on the owning journal record, sampled in the
SAME SQL statement as the chunk. A change yields409 `field_version_changed_restart`
with the current version/size but NO data. Discard old collected chunks and restart
that field at offset0. Versions are not content signatures or a pinned snapshot.
An unrelated audio-state change does not invalidate a message-body record version;
a change to another column of the same owning record may require restart.

Operator CLI example (all values/reference metadata come from an authorized page):

```sh
node scripts/whatsapp-read.mjs --profile-file "$PRIVATE_OPERATOR_PROFILE" --limit 700
node scripts/whatsapp-read.mjs --profile-file "$PRIVATE_OPERATOR_PROFILE" \
  --resource read_snapshot --row "$ROW" --field body --version "$FIELD_VERSION" \
  --offset 0 --length 16384
```

Repeat with next_offset until complete. Native `whatsapp_read` also accepts row,
field, version, offset and length, ALWAYS scoped to its immutable trusted-event chat.
It propagates ordered oversized outcomes rather than pretending the conversation
is empty. Historical-ledger profiles explicitly refuse this linked-device field API.
Operator-wide approval and selected/delegated limits are unchanged; a row reference
or cursor never grants authority.

## Application memory and database limits

SQL projects length/type and a value ONLY if its field is at most64KiB. Larger fields
are NULL in the driver result and described separately. The constructor processes
one bounded candidate at a time, marshals that candidate and charges its actual JSON,
order entry and derived summary BEFORE appending. An inline encoded row is at most
512KiB; otherwise it becomes an explicit reference. Message projection has13 fields,
so one candidate's raw driver values are bounded by13*64KiB, not arbitrary DB lengths.
JSON escaping can temporarily expand a bounded candidate (up to6x raw text plus
structural overhead). Accumulated payload is bounded before final encoding, with
128KiB reserved for the bounded envelope/late connection/gap/freshness metadata.
The final checked HTTP encoding is at most4MiB. Exact retrieval projects at most16KiB
into Go and replies within64KiB. Invalid observation scalar types are represented
exactly through references and explicitly invalidate freshness certification.

These are application construction/payload bounds, **not a measured or fabricated
RSS quota**. SQLite may allocate/cache/decode an entire stored record/CAST internally;
its limits, the driver, Go allocator/GC residency, request/config parsing, upstream
SDK/history and concurrent requests have separate costs. This patch does not claim
to cap those allocations. It prevents Go from accumulating all10000 large fields
and encoding the whole unbounded result before a downstream rejection.

## Observed proof

Settled `op-1792191864289472-18092-1075`, exit0, complete output: Go35 top-level
connector tests plus2 mutation subtests passed; vet passed; Node6 passed with zero
skips; native byte facade6 checks in BOTH source/embedded modes passed; MCP44 per
mode plus retained postcheck passed; shipping closure and119 checks passed.
The actual old clean artifact reproduced28,129,906 bytes and
connector_response_too_large in the new private fixture. The new process delivered
all700 exact40000-byte bodies once in seven actual MCP stdio pages (first six
4,023,753 bytes; final4,023,429), including metadata. A higher-ID insertion did not
enter the older continuation. Large Unicode body and transcript reconstructed
exact hashes through68 and41 chunks; chat holds/post acknowledgements were exact
and bounded too. Oversized late metadata produced a small503 page_no_progress,
not HTTP200/false complete. No real account or network pairing occurred.

A second fresh process generation, `op-1792191995686077-18092-1078` (exit0), increased
that individual body to5,500,000 bytes—larger than an entire page—and reconstructed
it exactly through336 chunks. The original first-generation68-chunk result remains
preserved, not overwritten. The700-row/escaping/transcript/chat/posting/version/
authority/no-progress and both native-mode checks also passed in that generation.

Coordinator generation2 receipt was read, not rerun or overwritten; its original
28,136,911-byte result remains separate (synthetic IDs/metadata differ). Generation1's
coordinator URL typo is not a connector failure. New dev/final generations and old
manifests remain immutable, with exact paths/hashes/source bindings in the final
local evidence manifest.

## evaluation

Harness: used. Graph: not-used in this continuation (active graph/Cargo/host-graph
owner respected; no source edits in those seams). Code mode: used for exact-read
structural page/fixture edits. Native Rust was built only from this owned checkout's
unchanged host source to verify the changed WhatsApp Lua facade; no graph repair,
Cargo source change, gate or other owner's source edits. Original cumulative
feedback remains in WHATSAPP-DELIVERY.md and WHATSAPP-REVIEW.md.

The coordinator's real reproduction exposed a genuine missing byte bound; row caps
and downstream rejection were not sufficient. This is corrected before encoding
whole pages, not excused as a transport limit. Native edit preflight twice refused
nonmatching SQL-selector/no-op text with effect:none; bounded rereads supplied exact
bytes and no unknown effect was replayed. A path-resolver callback arity mistake in
the new test was corrected before execution. All executed new generations passed;
there is no fabricated failure/saving/RSS or billing metric. Subjective improvement:
keep explicit wire-byte tests at transport boundaries and distinguish SQL-engine
allocations from application construction bounds. No recursive tool fixes started.

## Proof and remaining boundaries

Focused Go tests cover byte/row boundaries, exact last-delivered cursors, UTF-8,
escaping, field versions, malformed scalars, bounded metadata refusal and all three
page resources. A new private real-server+MCP stdio/HTTP fixture reproduces the old
700x40000-byte failure and delivers all700 exact rows once through bounded new pages,
while inserting a new higher row between older pages. It also retrieves oversized
body/transcript/chat-hold/post-ack bytes exactly, checks narrow/foreign/stale scopes,
read-only field whitelist and no-progress refusal, and exercises source+embedded
native event reads. Exact results/logs/source hashes are retained in the new evidence
manifest; original coordinator generations and prior successful manifests are untouched.
No real WhatsApp account, QR, send, engine weights, service installation, cloud/SSH,
Linux runtime or broad gate. Existing safe legacy cutover/private pairing blockers
remain. No general send, unknown-send/gap reset or permission widening was added.
