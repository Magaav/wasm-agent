# Return-bottom repair evidence

Independent 4291527 reviewer reproduced main follow=false at bottom after 50ms. Anchor scroll handling now derives resumed follow from selected container bottom position after releasing answer-start, for both main and child. It does not rearm anchor or change sibling state. Main jump remains main-only; context-switched child pin reads its own state. Existing replay force-pin behavior unchanged.

Normal UI browser regression includes async reader release/return-bottom and subsequent growth, plus prior child delta/reply/frame and sibling invariance checks. Removing resumed-follow fix causes normal scripts/test-ui.ps1 to fail; restored final suite passes.

Wrapper clears WA/WASM_AGENT/PI environment before fixture overrides, binds source-root/private home/database, requires exact wire9 and loop55 terminal verdicts, Pi bridge terminal plus native adapter15 verdict, and parses browser-owned pass/exit/signal/error. Every process receipt retains status/signal/error. No generic nested PASS search or gate invocation.

Actual embedded Pi JS private fake package adds malformed signature, mixed content indices/global stopReason, cancellation and provider error after provisional text. Output preserves provisional event before error and never emits false early begin. Native adapter15 now runs normally with candidate executable. Duplicate raw text delta is not modeled as replay-safe: Pi iterator deltas are ordered content fragments, not idempotent events. No invented dedup protocol or model-control stage.

Final normal suite: wire9, loop55, native adapter15; 0 skips; original UI four stages and shared browser pass. Raw logs, receipts/events and hashes retained in owned Git metadata resume-evidence/. Early provider timing remains conditional/synthetic; no live provider measurement, deployment, correctness certification or independent acceptance inferred. Combined backend lookup remains separate review scope. gate_verified:false; release_verified:false.
