# Portable automation artifacts

A job definition is bound to the machine it was written on: an absolute trigger directory, an absolute
script, an explicit CDP page, an operator's session. That is correct for a *local* rule, and useless as
something to copy to another node. A **portable artifact** is the same intent with every machine binding
replaced by a **named resource slot**, so it can be exported, reviewed and imported without carrying a
path, a machine address, a session or a credential with it.

Artifacts are versioned (`schema_version`). An unknown schema or a future version is refused, never
guessed at. Importing installs the job **disabled**; enabling stays a separate, deliberate act.

## The schema

```json
{
  "schema": "wasm-agent/automation",
  "schema_version": 1,
  "id": "documents",
  "name": "Validate incoming",
  "description": "optional",
  "trigger": { "kind": "file", "pattern": ".json" },
  "action": { "kind": "run", "timeout_seconds": 60 },
  "resources": [
    { "slot": "trigger_path", "kind": "file_directory", "required": true },
    { "slot": "script", "kind": "script_path", "required": true }
  ],
  "requirements": { "child_capacity": 0, "browser": false, "network": false, "elevation": false },
  "scope": { "owner": "operator", "role": "operator", "guest_owned": false }
}
```

The trigger and action keep their normal shape, minus the bindings that became slots:

| installed job field | becomes |
| --- | --- |
| `trigger.path` (file) | the `trigger_path` resource of kind `file_directory` |
| `trigger.websocket_url` (cdp) | the `page` resource of kind `cdp_page` |
| `action.script` (run) | the `script` resource of kind `script_path` |
| `action.session` (wake/subagent) | kept as a logical name, not a machine binding |

`requirements` is what the artifact says it needs from the host or the operator: reserved child capacity
for an inference action, a browser for a CDP trigger, network for a model call, elevation for anything
that would need more authority than the importing role holds.

## Export and import

```
wa-sentinel job export documents > documents.artifact.json
wa-sentinel job requirements documents.artifact.json      # what must be bound locally
wa-sentinel job import documents.artifact.json --bindings bindings.json --approve
```

`bindings.json` maps each required slot to a local value:

```json
{
  "trigger_path": "C:/approved/incoming",
  "script": "C:/approved/procedures/validate.sh"
}
```

The rules, and why each exists:

- **Every required slot must be bound**, and the value must be the right kind: a file path must be
  absolute, a page must be an explicit loopback DevTools page. A missing or wrong-shaped binding is a
  refusal, not a default.
- **Bindings need explicit approval.** `--approve` authorises the *binding*; it does not enable the job.
  An artifact cannot approve itself, so the approval is an argument from the operator, never a field the
  artifact carries. A binding for a slot the artifact did not declare is refused, not ignored.
- **The artifact is an allowlist, checked on import too.** Only the known portable fields are accepted: a
  raw `trigger.path`, `trigger.websocket_url` or `action.script` is refused (`artifact_contains_raw_binding`)
  rather than allowed to bypass the resource slots, and an unrecognised field is refused
  (`unknown_artifact_field`). The same credential/machine-binding scans that guard export guard import.
- **The importer's role is explicit.** `--as-role operator|master|guest` (default `operator`) is the
  caller's authority, and only those values are accepted - a typo is `unknown_importer_role`, never a
  silent operator. It is recorded on the imported definition as `imported_by`, so a later reader never has
  to trust the artifact's own scope claim.
- **The import is always disabled.** New and edited definitions are disabled by the same rule everywhere
  (`docs/JOBS.md`): editing invalidates approval.
- **Revision-safety is the job store's.** An identical import is a no-op - it does not bump the revision
  and does not cancel queued deliveries. A changed import bumps the revision, disables the job and
  cancels its pending deliveries, exactly like a local edit.

## What must not leave

Export is an **allowlist**: an installed job with an unrecognised trigger/action field is refused
(`unknown_job_field:...`), so a hidden binding or credential in an unexpected field cannot be silently
dropped or shipped, and only the known portable fields are emitted. It also refuses to produce an artifact
that still contains:

- a **credential-shaped key** anywhere (`token`, `secret`, `password`, `credential`, `authorization`,
  `api_key`, `private_key`, `access_key`) or a **credential-shaped value** (`sk-…`, `xoxb-…`, `ghp_…`,
  `AKIA…`, `-----BEGIN …`, `authorization: bearer …`, `token=…`); and
- a **machine binding** anywhere, including a nested param, a prompt or a context string: a drive-letter
  path (`C:\` / `C:/`), a POSIX absolute path (`/home/…`, `/tmp/…`, `/c/…`) or a loopback websocket
  (`ws://127.0.0.1`, `ws://localhost`, `ws://[::1]`).

The scan is deliberately blunt, and it is defence-in-depth behind the allowlist - it is not claimed to be
a total secret detector. A relative path (`scripts/reply.mjs`) is not a binding and passes.

## Guest scope is not a smaller operator scope

Guest scope is the **importer's** authority, not the artifact's claim. A guest import (`--as-role guest`)
is restricted whatever the artifact says about itself, and an artifact that declares `guest_owned`,
`owner: guest` or `role: guest` is restricted even when an operator imports it. An owner/role disagreement
is `inconsistent_artifact_scope`, refused rather than resolved in the artifact's favour. A guest-owned or
guest-imported artifact:

- may not set `requirements.elevation`;
- may not be a `subagent`. The runtime executes a child as the local operator and does not yet enforce a
guest principal at dispatch, so an `imported_by: guest` claim would not match execution; the import is
refused (`guest_subagent_requires_principal_binding`). This applies even to the guest-named
`job-deterministic` profile and to a guest-owned artifact imported by an operator - a profile name is not
a principal binding. A local operator import of the same artifact remains allowed; and
- may not be a `wake` (the operator's own conversation) or a `run` (operator-controlled shell).

An artifact that says `owner: operator` therefore cannot hand a guest operator capabilities, and a guest
cannot select an arbitrary profile id. This is checked in `rust/wa-jobs/src/artifact.rs`, structurally,
not by asking the model to behave.

## Profiles and the `subagent` action

A portable job's inference action is a `subagent`:

```json
{ "kind": "subagent", "profile": "whatsapp-responder", "prompt": "...", "timeout_seconds": 900 }
```

The profile is a **local, approved** config at `<config>/subagent-profiles/<id>.json`
(`schema_version 1`, `id`, `instructions`, `allowed_tools`, `resources`, `limits`). It is where machine
bindings live, so the artifact stays portable:

- `allowed_tools` is the tool envelope. The runtime registry exposes only these; a tool outside the list
  is refused even if the registry is wrong.
- `resources` binds the things the run may touch: the conversation, the self destination, the account,
  the browser endpoint, the send path and whether sending is approved.
- `limits` bounds context, body size and sends per run.

An event can **narrow** what a run does; it can never widen it. There is no argument that grants send
approval or reaches another conversation.

The `whatsapp-responder` profile ships as a template in `jobs/profiles/whatsapp-responder.json`. Its
scope is empty and sending is unapproved, so its default is "read nothing, send nothing".

### Scope is an account allow-list, narrowed by a trusted event

A profile may permit several *direct* conversations (`conversation`, `allowed_conversations`, or a single
`allowed_conversation`), and it gates the two capabilities separately with `actions`
(`["read","send"]`): a profile that may read a conversation is not thereby allowed to send. The run never
chooses the conversation from a model argument: the runtime resolves `ctx.event = {conversation_id,
message_id}` from the ledger, and the tool refuses a foreign `conversation_id` argument, a conversation
outside the profile's scope, or a ledger row that belongs to a different conversation. So the scope is
locally approved, and the event can only narrow it to the one conversation it actually names.

### Trusted context, not the event body

The tools read only trusted context, never the event payload beyond identity:

| seam | meaning |
| --- | --- |
| `ctx.event` | `{conversation_id, message_id}`, resolved by the runtime from the ledger |
| `ctx.effects` | the durable effect store: `reserve({message_id,conversation_id,body,limit})`, `confirm({message_id,conversation_id,message})`, and `record(decision)` for decisions, plus optional read-only `reconcile`/`release`/`unknown` |
| `ctx.subagent` | the runtime's resolved snapshot (`id`, `allowed_tools`, `resources`, `limits`); the tool reads this instead of re-reading a file a child could change |
| `ctx.profile` / `ctx.profile_path` | the local approved profile (tests/direct callers) |

The event's other fields are ignored: an event cannot supply a `reply_script`, a `store_send_script`, a
browser endpoint or a capability. A decision is written through `ctx.effects.record` (durable, keyed by the
message id, and it must not clobber a send reservation). A send is gated by an **atomic reservation**:
`effects.reserve` persists the pending effect and consumes the per-run budget **before** the send, so a
crash in the send/confirm window cannot replay. `reserve` returns `already_sent` (do not send), `ambiguous`
(a prior pending send may have happened - reconcile read-only or refuse, never send) or `budget_exceeded`.
After a store-verified send, `effects.confirm` must persist; if it does not, the tool reports
`send_not_confirmed`, not success. A missing effect store or capability is a refusal, not "unlimited".

### Routes and the unread marker

- `send_path = "ui"` is the deterministic reply tool. It opens the chat, and opening clears the unread
  marker, so a **non-self** target always needs `allow_mark_read = true`; a **self** target is allowed here
  and the raw script independently refuses it when its unread is nonzero or unproven (a
  manually-marked-unread notes-to-self has unread too). The self check is against the app's own identity,
  never a string match. When `allow_mark_read = true`, the tool passes `--allow-mark-read` to the raw
  script - derived from the profile only, never from an event.
- `send_path = "store"` requires a `store_send_script`. Declaring `store` cannot make the UI script bypass
  the unread guard. The store script is an operator-asserted local binding: accept it only because the
  operator approved it, and do not claim it is a proven store route.
- Any other route value is refused.

The route must also prove the bound **identity**: when the profile binds `account` and/or
`browser_endpoint`, they are passed to the raw script as `--expect-account`/`--expect-browser-endpoint`,
and the script refuses a session logged in as a different account or against a different page before it
opens or types. The tool re-checks the identity the route reports (`account`/`own_id`,
`browser_endpoint`/`endpoint`); an unproven or mismatched identity is `send_account_unproven`,
`send_account_mismatch`, `send_endpoint_unproven` or `send_endpoint_mismatch`, never a success. An account
compares by digits only when both sides are phone/PN shapes (`@c.us` / `@s.whatsapp.net`, or a
bare/formatted number); a `@lid` or a label compares exactly, so `operator1` never equals `other1`. An
endpoint compares protocol, port and page id exactly, and only genuine loopback aliases
(`localhost`/`127.0.0.1`/`[::1]`) are interchangeable; a non-loopback host never matches a loopback
binding.

The script's result is verified: the host wrapper's exit code must be zero, its stdout must decode, and
the decoded result must prove the exact recipient, body and message id (`verified: true`). A shell exit
code is never a send.

See `docs/JOBS.md` for the deterministic eligibility rule that decides which messages even reach a profile.

## Proof

- `cargo test -p wa-jobs --offline` covers export stripping, the field allowlist (unknown fields
  refused), credential/machine-binding refusal (including nested params, prompts and context, POSIX paths
  and value credentials), raw-binding refusal on import, unknown binding slots, required and approved
  bindings, loopback page bindings, importer-role allowlisting and normalization, owner spoofing and
  inconsistent scope, unknown schema versions, and the store-level install-disabled and revision-safety
  round trip.
- `tests/whatsapp-scoped.lua` covers the profile-scoped tools: conversation scope, decision-without-send,
  send approval, the unread blocker, body and per-run limits, the atomic reserve/confirm contract
  (crash-window replay, ambiguous reconciliation, budget, persistence failure) and the approved-flag
  pass-through.
- `tests/whatsapp-reply-core.js` covers the raw-script guard: a non-self `--send` is refused before the
  chat is opened unless unread clearing was explicitly accepted, and a notes-to-self send is allowed.
- `scripts/test-job-subagents.cjs` (run with `node scripts/test-job-subagents.cjs`) starts a real sentinel against
  an isolated home and a local `/subagents` protocol fixture: it imports an artifact through the public
  CLI, proves import-disabled, reserved-capacity execution while the node is busy, exact start payload and
  idempotency key, settlement only on a settled child, `unknown` without retry, waiting without reserved
  capacity, guest import denial, and the scoped-tool denial suite. No paid inference.
- `docs/WHATSAPP-PROOF.md` is the self-chat live-proof setup (performed by the coordinator, not here).
