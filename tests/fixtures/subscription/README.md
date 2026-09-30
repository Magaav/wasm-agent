# Recorded subscription streams

Two real SSE streams, recorded from `https://chatgpt.com/backend-api/codex/responses` through
**this repository's own wire** (`lua/core/subscription_wire.lua` over `host.http_sse`), with Node and
Pi absent. They are the endpoint's bytes, not a reconstruction, and they are what
`scripts/test-subscription-wire.lua` (the offline parser test) and the `sse_line_tests` in
`rust/wa-host/src/host.rs` (the line reader) are tested against.

| file | what it is | shape |
| --- | --- | --- |
| `codex-responses-sse.txt` | a stream that ends in a tool call | `response.created`, `response.in_progress`, `response.output_item.added` (function_call), 5 × `response.function_call_arguments.delta`, `response.function_call_arguments.done`, `response.output_item.done`, `response.completed` |
| `codex-responses-sse-text.txt` | a stream with text in it | the same, plus a message item: `response.output_item.added`, `response.content_part.added`, 8 × `response.output_text.delta`, `response.output_text.done`, `response.content_part.done`, `response.output_item.done` (phase `commentary`), then the tool call above |

Both are one line per wire line, with the SSE framing intact (`event:` line, `data:` line, blank line
between frames) - that is how the transport hands them to Lua, so the framing is under test too.

Measured, and worth knowing before trusting a parser: **this endpoint does not send the
`data: [DONE]` sentinel.** The last frame is `response.completed` and the body simply ends, so a
reader that waits for a sentinel would call a finished stream truncated. The parser accepts a
`[DONE]` line if one ever appears, and neither fixture has one.

**How they were recorded.** `scripts/check-subscription-wire-live.lua`, which makes the two real
requests this folder must be able to explain:

```sh
WASM_AGENT_LUA_ROOT=<repo> WA_SCRIPT=scripts/check-subscription-wire-live.lua \
  <repo>/rust/target/release/wa --db <scratch>.db
```

That command needs the network and a live credential, so it is not part of the gate. Re-run it when
the endpoint changes: a fixture that no longer matches is the first thing a future break should fail
on, and the failing test names the field.

**Redacted, and nothing else.** Four fields are replaced with the literal `<redacted>`:
`prompt_cache_key`, `safety_identifier`, `user_id` and `account_id` - each is either the caller's own
session/cache identity or an account identifier, echoed back in `response.created`,
`response.in_progress` and `response.completed`. The `Authorization` header and the access token
appear nowhere in a response body, so no credential is in these files; the recording script asserts
that the four fields above are the only replacements it makes.

Response and item ids (`resp_...`, `msg_...`, `fc_...`, `call_...`) are **not** redacted: they are
per-response identifiers, and they are the evidence that the id shapes the client relies on
(`call_id|fc_item_id`, `msg_...` message ids) are real.
