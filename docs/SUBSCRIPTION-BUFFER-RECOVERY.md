# Upstream retry-buffer HTTP507 recovery

## Observed incident

The retained original parent run `710f3e31-b555-43c8-88eb-9b4869550a93` failed at message6815. Its first prepared native subscription request (event141592) was3620932bytes and succeeded at586190 provider input +106 output. The next append-only request (event141597) was3624646bytes (+3714), with unchanged tools/model/routing. It returned HTTP507 after880ms, before any SSE event. Diagnostics at141598 explicitly recorded `retry_safe:true`, `retryable:false`, parser events0 and no unsafe/terminal state. One earlier read_many already completed; no failed-response tools were dispatched. Failed provider usage is unknown.

These are recorded prepared-request bytes, not billed tokens or a discovered gateway limit. They do not identify the original upstream failure or proxy version. The same error text is documented by Envoy contributors in [envoyproxy/envoy#15211](https://github.com/envoyproxy/envoy/issues/15211): a proxy may stream a large initial request successfully but fail to buffer it while waiting for an upstream retry/backoff. Thus a near-identical succeeding request and later507 are compatible. This is not proof of local disk exhaustion, a model context limit or a hard maximum body size.

## Local defect and repair

Native inference recovery classified network failures, explicit transient SSE errors and HTTP500/502/503/504. It did not classify the observed507, so a retry-safe pre-stream request ended as `subscription_retry_suppressed`. The exact old policy is retained as a causal test control.

The new narrow class accepts HTTP507 only when its complete plain-text body is exactly `exceeded request buffer limit while retrying upstream` (optional final period/outer whitespace), with no conflicting host error and an empty, nonterminal, safe parser. Generic507/Insufficient Storage, quota/authentication errors, other statuses, JSON/HTML/suffixed/unknown bodies and parsed output/effects do not acquire retry authority. Existing unknown-effect, cancellation, deadline and explicit disabled-retry rules remain.

It regenerates inference with the same complete serialized request, through the existing bounded backoff/retry budget. Completed earlier tools remain in the ledger/context and never execute again. Only a validated completed response reaches dispatch. No installer, send, notification, failed tool, user task or old run is replayed.

Failed-attempt diagnostics now retain actual wire request/response byte sizes and hashes plus `recovery_class:upstream_retry_buffer_overflow`, without prompt/header/credential payloads. Request bytes and provider tokens are distinct constraints. The configured92% context trigger, full reasoning replay, original transcript and50KiB tool view budget are unchanged; no forced early compaction, silent clipping, larger output budget, fallback provider or new scheduler is introduced.

Risk: the upstream may have performed or billed abandoned inference; retry cost/usage remains unknown even when the recovered result reports usage. Persistent gateway failures can exhaust the existing budget/deadline and must remain visible. This prevents the observed one-off classifier stop, not a promise that production can never fail during an external outage. A repeated body-buffer failure is diagnostic evidence for a future byte-aware policy; it is not permission to discard context or guess a proxy limit.

## Verification

`node scripts/test-subscription-buffer-recovery.cjs <built-wa> <fresh-evidence>`, then the same CLI with `--post` first. Source and standalone embedded cases cover the exact incident, same-body preservation, multi-megabyte requests, HTTP507→SSE success over a real localhost socket, unknown507 refusal, parser/unknown-effect/status/body negatives, cancellation, explicit retries0, exhaustion/deadline, actual agent/provider prior-tool preservation and durable size/hash diagnostics. The pinned old-wire control must fail the exact507 oracle.

Existing streamed-server-error, native disconnect and overflow suites run in both modes. The peer is process-owned, retained and drained, never a browser/client or paid provider. Candidate/local-socket proof is distinct from exact-source Sentinel installation and future real upstream recovery; no live507 was deliberately provoked or historical inference replayed.
