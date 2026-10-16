# OpenAI subscription Fast mode — isolated Stage1 (2026-10-16)

Historical Stage1 record. The subsequent wired feature and scope are documented
in [OPENAI-SUB-FAST.md](OPENAI-SUB-FAST.md); the original evidence below is retained.

**Not installed, not wired, not integrated.** This commit adds a pure Lua policy
and focused fixtures only. Existing provider/auth/UI/settings/serve files are
unchanged. No credential access, account setting, paid request, benchmark change,
transport fallback, worker, publication or default enablement was performed.

## Contract established from source

Repository base: `origin/main d4dfc0ce57a63ff84367f07371393e2a6fe68c4a`.
The existing native endpoint is `https://chatgpt.com/backend-api/codex/responses`
(`subscription_wire.lua`); native remains the production transport. The existing
Pi-derived catalogue is Pi0.87.1, imported2026-09-30. It has thinking metadata
but **no service-tier/account entitlement metadata**. No Fast helper existed here.

Public upstream source inspected and retained at exact Codex commit
`6ae8b8aa7c608730d4315d59c5c081897ae02780`, fetched2026-10-16 from
`https://raw.githubusercontent.com/openai/codex/<commit>/<path>`:

| Path (under codex-rs/) | SHA256 |
| --- | --- |
| protocol/src/config_types.rs | ce9b26223db7cc4b5cf474e571e4509e8cc52536e159510f153f94de0fcd37e8 |
| protocol/src/openai_models.rs | 4b080aeaf5c158104e27d8277f3bc03ee3ad55b55a41c30a788d831fb2e2a99f |
| codex-api/src/common.rs | 3ab2c9406e2e9b465b7b23756991bf7893bd884be9af3cff8c222bb26a8df4a0 |
| core/src/client.rs | 5c0dd767eeb5d8740ed67b4d6037c44cde80ad3cba3c7d242cdfdf21a406b2a8 |
| tui/src/chatwidget/service_tiers.rs | 7ffacb772d0917e80e51367b34c19dc70bf73d823efbb1a5bc58929a86cee3b1 |
| tui/src/service_tier_resolution.rs | b4ab82c1b362accc6d0d8e78abe82a764e97ec0cf19e88b372578ca9011a94ac |

Key findings:

* `ServiceTier::Fast.request_value()` is **`priority`**; `fast` is an accepted
  config alias. The model catalog can advertise an exact service-tier id. This
  helper preserves an advertised `fast`/`priority` id, otherwise uses `priority`.
* Explicit OFF is **`default` in selection**, not absent preference inheriting
  `default_service_tier`. Codex's UI toggles to this explicit sentinel.
  `ModelInfo::service_tier_for_request` then **omits the HTTP field** for it;
  `ResponsesApiRequest` skips `None`. This helper likewise clears an existing
  expensive tier OFF and never consults catalog defaults. Sending wire `default`
  is NOT justified by this pinned subscription client. The omission is deliberate
  Standard selection, not an accidental inheritance in our local resolver.
* `client.rs` builds that request for Codex backend HTTP and WebSocket paths.
  This is subscription-client source evidence, not merely public API analogy.
  It is not a live proof that a particular backend/account honors either tier or
  that no future server-side default can exist. Unknown actual stays unknown.
* Upstream filters unsupported tiers; this helper instead visibly refuses an ON
  choice when explicit metadata excludes Fast or the model is unknown. It never
  silently changes the tier/model/reasoning/provider or retries.
* Requested tier and terminal `response.service_tier` are distinct. Missing,
  malformed or empty actual tier remains unknown. `priority`/`fast` normalize for
  comparison only; other returned strings remain visible, including downgrades.

Coordinator-supplied official research (not independently browsed in this child):
[Speed](https://learn.chatgpt.com/docs/agent-configuration/speed) documents Fast
for GPT-6.1 Sol / GPT-6 Astra / GPT-6 Sol / GPT-6 Luna where available. Included
subscription allowance usage is2.5x Standard; purchased credits/Enterprise PAYG2x.
These are **usage premiums, not raw generated-token multipliers or guaranteed
throughput**. [API guide](https://developers.openai.com/api/docs/guides/fast-mode)
documents `fast`/`priority`, but does not alone establish subscription entitlement.
Coordinator cached refs: `172baf6101be25cfef8fdb363ebc3ced651cc531be9d313e3e5f36e98c5b0d9d`
and `0c572b2229b5186c9361d2eb5a6cf5dd3e81b0bf0f36512dd72c1ce24601932d`.
Help Center403 was not retried. Ultrafast is separate and excluded.

## Added API (internal pure module, no tool/setting authority)

`openai_sub_fast_policy.lua`:

* `selection(provider, model, enabled, entry)` — strict boolean; missing is OFF;
  distinct documented/advertised/unsupported/unknown model support; account
  entitlement always unknown. Foreign providers retain preference but are inert.
  Optional `entry.id/service_tiers` uses existing id/upstream metadata conventions.
* `request(body, selection)` — shallow copy changing only native service tier for
  openai-sub. Does not own any other provider's request or sanitize foreign bodies.
* `observation(selection, terminal_response)` — requested vs actual, known/match
  metadata only. Does not touch usage, bill, quota, retries or transport.

## Verification and retained evidence

Self-review, not independent review. All tests are synthetic/offline.

```
node scripts/test-openai-sub-fast-stage1.cjs <absolute-wa.exe> <fresh-evidence>
openai-sub fast stage1 ok (108 checks; no network; source-root only)

WA_SCRIPT=scripts/test-subscription-wire.lua <wa.exe> --db <private-db>
subscription wire ok (175 checks)

node scripts/test-direct-workflow-instructions.mjs
{"ok":true,"checks":33,"skipped":0,...}
```

Both Lua runs explicitly set `WASM_AGENT_LUA_ROOT` to this owned checkout and
private homes/DBs. The executable was read-only
`C:/Users/Victor/orca/projects/wasm-agent/rust/target/release/wa.exe`;
**embedded modules were not tested or rebuilt**. The runner records binary and
source hashes, exit/signal, stdout/stderr hashes and source root in `receipt.json`.
Retained evidence is under this worktree's Git metadata (`git rev-parse --git-path`):
`fast-stage1-test-1` (initial101-check pass), `fast-stage1-test-2` (108-check pass),
`fast-stage1-regression-1` (175-check pass), `fast-stage1-upstream-1` (full pinned
public source files). No focused test failed; early discovery commands had
missing candidate paths/globs, not a test failure.

Coverage includes four documented model ids, unknown/unsupported model metadata,
foreign providers, OFF/ON and absent preference, exact JSON serialization,
unchanged model/LOW reasoning/tool concurrency/request fields, input/cache/output/
reasoning counts, alias/downgrade/missing actual tier, and current native SSE usage
normalization. HTTP functions are replaced with immediate failures in the fixture.
The test explicitly proves the current parser does **not** expose actual tier yet:
that remains a Stage2 dependency, not a falsely passing integrated assertion.
No UI tests/screenshots, embedded build, full gate or live entitlement/throughput
checks were run. `gate_verified:false`, `release_verified:false`.

## Stage2 dependency — only after provider owner settles and coordinator follows up

Re-read landed shared files first; these names are from the base, not instructions
to duplicate or interfere with the active provider recovery implementation.

1. `lua/core/state.lua`: extend existing `selection_key`/`mutate` and revisioned
   node-selection snapshot with the Fast preference; no separate settings store.
   `provider.lua` setters/`pin` must atomically freeze provider/model/reasoning/Fast
   for the next run; worker/profile applicability must remain explicit OFF unless
   authorized. Retain preference on provider switches but never send it to Go.
2. `provider.lua` subscription branch near `subscription.complete` passes pinned
   applicability via native options; `subscription_wire.lua` `M.body` calls the
   pure request policy. Preserve vault/native transport and current quota/retry/
   cancellation/unknown-effect rules. Refused Fast must be visible, not replayed
   at Standard or another route. Follow pinned policy for internal summaries too.
3. `subscription_wire.lua` terminal `finalize(response)`/`session.result` must
   capture actual tier before it is lost; record requested/actual separately in
   existing provider observability/trace results. Never multiply raw usage.
4. `lua/core/server.lua` settings payload/CAS setters (base around1116–1233),
   existing authenticated Rust settings routes, and existing role/node/remote
   controls carry revisioned preference/support/unknown entitlement metadata. No
   guest/child model tool or unauthenticated upcharge endpoint.
5. `ui/app.js`: existing balloon settings controls, `applySettings` stale revision
   fencing (base3509), `post` CAS body (3535), and `lockControls` (2684).
   Reuse `ui/components.js`/existing status balloon and DESIGN5px tokens; openai-sub
   only Fast checkbox, visible support/entitlement uncertainty and usage premium.
   Child read-only views stay read-only per SHARED-CHAT. Follow changed owner code,
   not these historical line numbers. Preference edits apply NEXT turn only.
6. After source/settings/native-snapshot/embedded regressions, causally test staged
   Chromium UI, inspect screenshot, then run `test-ui.ps1` once. No live Fast probe
   or account enablement. Coordinator alone publishes. This Stage1 commit stays
   local and unintegrated until authorized followup.
