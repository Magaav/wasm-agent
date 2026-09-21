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
  artifact carries.
- **The import is always disabled.** New and edited definitions are disabled by the same rule everywhere
  (`docs/JOBS.md`): editing invalidates approval.
- **Revision-safety is the job store's.** An identical import is a no-op - it does not bump the revision
  and does not cancel queued deliveries. A changed import bumps the revision, disables the job and
  cancels its pending deliveries, exactly like a local edit.

## What must not leave

Export refuses to produce an artifact that still contains:

- a **credential-shaped key** anywhere (`token`, `secret`, `password`, `credential`, `authorization`,
  `api_key`, `private_key`, `access_key`); and
- a **machine binding** in free text: a drive-letter path (`C:\` / `C:/`) or a loopback websocket
  (`ws://127.0.0.1`, `ws://localhost`, `ws://[::1]`).

The second check is deliberately blunt. A prompt that happens to name `C:/some/tool` is not portable, and
silently exporting it is how a machine path travels to another node and fails there.

## Guest scope is not a smaller operator scope

An artifact may declare `scope.guest_owned`. A guest-owned artifact:

- may not set `requirements.elevation`; and
- may only name a profile in the guest-approved list (`job-deterministic`).

This is checked in `rust/wa-jobs/src/artifact.rs`, structurally, not by asking the model to behave. A
guest that imports an operator artifact gets a refusal that names the reason, not an elevated run.

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

A profile may permit several *direct* conversations (`allowed_conversations`, or a single
`allowed_conversation`). The run never chooses the conversation from a model argument: the runtime
resolves `ctx.event = {conversation_id, message_id}` from the ledger, and the tool refuses if that
conversation is outside the profile's scope or if a ledger row it reads belongs to a different
conversation. So the scope is locally approved, and the event can only narrow it to the one conversation
it actually names.

### Trusted context, not the event body

The tools read only trusted context, never the event payload beyond identity:

| seam | meaning |
| --- | --- |
| `ctx.event` | `{conversation_id, message_id}`, resolved by the runtime from the ledger |
| `ctx.effects` | `{find(message_id), record(record)}`: a durable effect store for decisions and sends |
| `ctx.sends` | `{count}`: the persistent per-child send counter |
| `ctx.profile` / `ctx.profile_path` | the local approved profile |

The event's other fields are ignored: an event cannot supply a `reply_script`, a `store_send_script`, a
browser endpoint or a capability. A decision is written through `ctx.effects` (durable, keyed by the
message id), and a send is idempotent on that same id - a repeated delivery is `already_sent`, never a
second send. A missing effect store or counter is a refusal, not "unlimited".

### Routes and the unread marker

- `send_path = "ui"` is the deterministic reply tool. It opens the chat, so it is allowed only when the
  bound conversation is the profile's **self destination** (notes-to-self clear nothing) or when
  `allow_mark_read = true` explicitly accepts the marker being cleared. The self check is against the
  trusted local binding, never an event assertion.
- `send_path = "store"` requires a real `store_send_script`. Declaring `store` cannot make the UI script
  bypass the unread guard.
- Any other route value is refused.

The script's result is verified: the host wrapper's exit code must be zero, its stdout must decode, and
the decoded result must prove the exact recipient, body and message id (`verified: true`). A shell exit
code is never a send.

See `docs/JOBS.md` for the deterministic eligibility rule that decides which messages even reach a profile.

## Proof

- `cargo test -p wa-jobs --offline` covers export stripping, credential/machine-binding refusal, required
  and approved bindings, loopback page bindings, guest elevation and unknown schema versions, plus the
  store-level install-disabled and revision-safety round trip.
- `tests/whatsapp-scoped.lua` covers the profile-scoped tools: conversation scope, decision-without-send,
  send approval, the unread blocker, body and per-run limits.
