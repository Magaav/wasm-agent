# Code-mode normal model-boundary correction

## Scope and causal defect

Fresh sync for this continuation: owned tree `e99788e6` → main
`bebef12a85ce6c46236c59be27be67a6fcc0fe35`, tree
`7fb47726d25efb4a7e536a6f53753f1cd89649fd`. Self-review, not independent review.
The coordinator's successful installation is not replayed or disputed.

The first presentation implementation was functionally incomplete. Its private
raw-dispatch/json.encode proofs did not cover normal model awareness. In
`codemode_view.exact`, an empty Lua table carried the entire native result in an
opaque `__json_raw` metatable. The normal agent path is:

1. `tools.dispatch` returns the code-mode result.
2. `agent.lua:2003` applies `redact.value`, recursively copying table fields.
   Opaque raw metatables disappear; an empty wrapper becomes an empty array.
3. `agent.lua:2031` projects that already-empty result, then emits it and stores
   the tool-content string for the next provider round (`2054` onward).
4. `server.lua:30-31` uses `host.stream(json.encode(event))` for SSE. Session
   inspection projects the stored tool-content string. Neither can restore data
   already erased before storage.

A private three-line authored file reproduces `complete:true,result:[]` with both
exact old codemode_view.lua source and the prior standalone installed binary,
SHA256 `de3833451ee028359e8f754b4b603093ebbd8ab48c02d6980356bbc204851d46`.
The control verifies the selected original has nonempty content and matches its
hash. No parent tool call was rerun and no parent/account original was needed.

## Correction and minimal shared seams

- Strict-parsed originals become real traversable fields, not raw JSON wrappers.
  `json_contract.materialize` retains null/empty-object/empty-array distinctions.
- The shared serializer and redactor recognize only payload-free empty-object and
  null tags on genuinely empty tables. Nonempty strings still traverse ordinary
  redaction; arbitrary raw metatables are NOT preserved. Default plain tables,
  ordinary decoding, schema admission and existing raw behavior are unchanged.
- Selected JSON keys use the same configured-secret replacement. Key collisions
  refuse presentation explicitly rather than dropping a field. Ordinary redaction
  policy for other tools was not redesigned.
- Presentation is explicitly a sanitized model view. Flags distinguish sanitization,
  configured-value replacements and key replacements; private originals and their
  hashes/byte offsets remain unchanged. Unredacted source/edit frames stay exact.
  A masked source string is not an exact old_text edit anchor.
- Packing measures the final sanitized object and labels, including redaction
  expansion. An8-byte configured value expanding to the10-byte mask can force
  explicit partial coverage even when the original itself fits. Global50KiB/8MiB
  ceilings, VM pins, roles/profiles/workspaces/catalogues and no-replay rules stay.

No edits to agent.lua, tools.lua, server.lua, host.rs, graph/Cargo, WhatsApp, UI or
AGENTS. Those files are inspected/snapshotted only where relevant to the boundary.

## Actual-agent proof, not raw dispatch

```
node scripts/test-codemode-model-boundary.mjs <built-wa> <fresh-evidence> [prior-binary]
node scripts/test-codemode-model-boundary.mjs --post <built-wa> <same-evidence>
```

The fixture runs the real agent with deterministic mock inference and actual Rust
Wasmtime/QuickJS. The next provider request contains the actual post-redaction,
post-projection tool-content string. Assertions also cover server-equivalent SSE
JSON serialization, stored rows, native exact paged session projection and process
restart. They do not inspect only `tools.dispatch` or pre-redaction JSON.

Coverage includes authored Unicode/escaping/caveats, all captured document counts
and EOF distinctions, original selection/version/edit frames, cached continuation
without live refetch, typed nested null/object/array/boolean/number values, caught
native failure, secret-bearing values/keys/metadata/errors, key-collision refusal,
post-redaction expansion, explicit oversized partial coverage and original retrieval
through actual agent/tool_result calls, nontext references, and earlier successful
write/later unknown+script failure with one write and no replay. Exposed provider,
SSE, session, stored-row and telemetry/tool-log data and process logs must not
contain the synthetic configured values. Private exact originals intentionally do.

Source and standalone embedded seed/restart runs require Node absent from child
PATH. The same collector runs existing18-check secret-redaction/real-agent and
18-check JSON parser regressions separately in each mode. It retains exact source
copies, tested/prior binaries, old source control, private SQLite/originals,
provider messages/SSE/session/telemetry projections, logs and hashes. No model API,
HTTP service or installed runtime is started/restarted by the proof.

Development generations remain under `rust/target/model-boundary-dev*`:
- dev1 caught a fixture's lossy decode/re-encode of null-array SSE data; corrected
  to assert exact exposed JSON fragments with the strict AST instead.
- dev2 caught a fixture assuming an oversized session row would be one unpaged
  message; corrected to use existing exact native session byte cursors.
- dev3/dev4/dev5 passed updated source seed/restart and both causal negative
  controls; their embedded positive case still used the intentionally old binary
  and correctly failed. These are NOT claimed as positive embedded proofs.

Final built-binary runs and retained postchecks are recorded in their fresh
collector receipts and the external delivery record. Earlier passing presentation
receipts are retained unchanged; they do not certify this corrected boundary.

## Evaluation and limitations

- harness: used. Actual-agent provider/SSE/session assertions exposed the prior
  blind spot; exact JSON fragments avoid the ordinary decoder's intentional
  null/object loss. Native session byte paging is necessary for large stored rows.
  Synthetic fixtures establish bounded correctness/privacy mechanisms, not paid
  quality, tokens, speed or universal performance. No full release gate.
- graph: used (`impact`, inbound depth1,6000-byte page). It resolved the M.run →
  presentation.finish caller and both dedicated proof files. The page was truncated,
  builtin calls unresolved, and vendor/json.lua excluded from the graph snapshot;
  direct source inspection and shared privacy/parser regressions cover that seam.
  It helped confirm the immediate caller, not prove complete compatibility.
- code mode: used only with ordinary raw read_many/text, not broken showCall.
  Native read_many result SHA256
  `1437c1d1d8360f313b53a2095b0e0d49adefd48c5210a5246629b0ac6928b635`
  retained10261 bytes, including source receipts. New presentation behavior is
  verified in private source/built runtimes, not claimed installed in this session.
- Exact-text edits refused ambiguous old_text in preflight with effect:none;
  bounded source evidence was checked and replacements narrowed. No unknown effect
  was replayed. This is reported, not used to start a tool-repair task.

No installation/deployment, Sentinel, client/remote/cloud access, account reads,
external agents or paid inference. `gate_verified:false`, `release_verified:false`.
Only the coordinator may authorize any later installation.
