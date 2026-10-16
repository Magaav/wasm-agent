# Subscription Fast mode

The OpenAI subscription status balloon contains **Fast mode** and an optional
**Fast mode for subagents** checkbox. Both use the existing revisioned node
selection store. The shipped preference remains OFF. Opening the balloon never
enables it or sends a provider request.

After installation, the coordinator/operator can select OpenAI subscription and a
supported model, then check Fast mode for eligible **future** operator turns.
Check Fast mode for subagents only to authorize the ordinary reserved
`orchestration-worker` profile too. This is an explicit persisted preference, not
a global environment default. Uncheck Fast mode for the persistent ordinary/Standard
escape. No model or reasoning selection changes; `/new` still starts a new thread.
The preference survives reload/provider switches; Go never receives the Fast tier.

## Scope and authority

- `off`: Standard everywhere.
- `on`: master operator runs without a subagent profile only.
- `coding`: those operator runs plus master `orchestration-worker` task owners.
- Guests, WhatsApp responders, explore and every other specialized/unrelated
  profile remain Standard. No broad profile file or default is rewritten.
- Child inference has no cost-setting tool. No worker may enable its own Fast
  preference. The ordinary coding-worker inheritance is controlled by the
  operator checkbox on its execution node, not an inference argument.
- POST `/fast-mode` accepts existing `{value,revision}` selection envelopes where
  value is `off`, `on`, or `coding`. It requires master authority, exact local-node
  scope and a current revision. Use a remote node's own operator UI; no relay.
  The coordinator has **not** enabled this preference on a live node in this task.

The agent passes its existing role/profile identity to `provider.pin`; that is the
only extra shared agent-file seam. The same SQLite snapshot freezes provider,
model, reasoning, Fast preference and revision. Credentials retain the existing
independent-source/generation fence. A settings write never changes an in-flight
run. Each request, including internal summaries, resolves applicability for its
actual pinned model; an unsupported Fast model errors instead of changing model,
reasoning, provider, billing route or tier. Explicit legacy Pi transport refuses
Fast; there is no native-to-Pi/Node fallback.

## Wire, usage and uncertainty

See [Stage1 source contract and pinned hashes](OPENAI-SUB-FAST-STAGE1.md).
Fast serializes as `priority` (or an explicitly advertised Fast id). Standard is
an explicit local `default` selection that clears the wire tier; the pinned Codex
client omits that sentinel on HTTP. We never inherit a catalog's premium default.
Both native and brokered subscription paths use this same Lua serializer.

Model support documented for GPT-6.1 Sol / GPT-6 Astra / GPT-6 Sol / GPT-6 Luna
is **not account entitlement**. The balloon says entitlement unknown. The official
[subscription Speed guide](https://learn.chatgpt.com/docs/agent-configuration/speed)
reports2.5× included allowance consumption or2× purchased credits/Enterprise PAYG.
Those premiums are explanation, not raw token multipliers, dollar estimates,
quota measurements or guaranteed throughput. Ultrafast is excluded.

Terminal `response.service_tier` is retained separately from the requested tier
in provider observations. Missing actual remains unknown; an actual downgrade is
visible. Refusals retain the existing visible errors/no-replay/cancel policies;
no surprise retry at Standard or another provider is introduced. Vault generation
failures now retain their named code instead of Lua's unhelpful `table: address`.

## Focused verification (synthetic only)

- `test-openai-sub-fast-stage1.cjs`: pure policy/JSON/native parser,108 checks.
- `test-openai-sub-fast.cjs <candidate> <fresh-evidence>`: source and standalone
  embedded native/broker serialization, summary and next-run snapshots, scope,
  restart, stale CAS, refusal/no-tier-fallback and generation fences.
- `test-openai-sub-fast-http.cjs <candidate> <fresh-evidence>`: real private node
  HTTP, concurrent admission/CAS, guest/remote/origin/revision refusals and OFF.
- `test-openai-sub-fast-ui.cjs <fresh-evidence>`: staged real Chromium, explicit
  preference writes, stale replies, locking/scope/support, requested/actual,
  command defaults; removing the toggle handler must fail. Inspect its screenshot.
- Existing provider recovery/management regressions and final-source
  `scripts/test-ui.ps1 -KeepEvidence` are retained separately with hashes.

Evidence lives in the owned worktree's Git metadata under `fast-stage2-*`;
failed generations are preserved. Receipts bind source/binary/assets/screenshots.
Self-review is not independent review. No live account/login/paid request,
throughput benefit or installed behavior was verified. No release gate or
publication is implied; coordinator alone installs the combined delivery.
