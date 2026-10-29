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
| `action.script` (run) | the `script` resource of kind `script_path` |
| `action.session` (wake/subagent) | kept as a logical name, not a machine binding |

`requirements` is what the artifact says it needs from the host or the operator: reserved child capacity
for an inference action, network for a model call, elevation for anything
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
  absolute. A missing or wrong-shaped binding is a
  refusal, not a default.
- **Bindings need explicit approval.** `--approve` authorises the *binding*; it does not enable the job.
  An artifact cannot approve itself, so the approval is an argument from the operator, never a field the
  artifact carries. A binding for a slot the artifact did not declare is refused, not ignored.
- **The artifact is an allowlist, checked on import too.** Only the known portable fields are accepted: a
  raw `trigger.path` or `action.script` is refused (`artifact_contains_raw_binding`)
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
a total secret detector. A relative path (`scripts/validate.sh`) is not a binding and passes.

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
{ "kind": "subagent", "profile": "reviewer", "prompt": "...", "timeout_seconds": 900 }
```

The profile is a **local, approved** config at `<config>/subagent-profiles/<id>.json`
(`schema_version 1`, `id`, `instructions`, `allowed_tools`, `resources`, `limits`). It stays on the
importing machine, so the artifact stays portable:

- `allowed_tools` is the approved tool allow-list, not the entire model-request envelope. The runtime registry exposes only these; a tool outside the list
  is refused even if the registry is wrong.
- `resources` may name `exclusive` shared resources the run must hold while it executes.
- `limits` bounds depth, time, output, prompt size and tokens per run.

A job, an event or the artifact itself cannot widen what the profile allows: the artifact names a profile
id, and the local approved profile decides the tools and limits.

## Proof

- `cargo test --manifest-path rust/Cargo.toml -p wa-jobs --offline` covers export stripping, the field allowlist (unknown fields
  refused), credential/machine-binding refusal (including nested params, prompts and context, POSIX paths
  and value credentials), raw-binding refusal on import, unknown binding slots, required and approved
  bindings, importer-role allowlisting and normalization, owner spoofing and
  inconsistent scope, unknown schema versions, and the store-level install-disabled and revision-safety
  round trip.
- `scripts/test-job-subagents.cjs` (run with `node scripts/test-job-subagents.cjs`) starts a real sentinel against
  an isolated home and a local `/subagents` protocol fixture: it imports an artifact through the public
  CLI, proves import-disabled, reserved-capacity execution while the node is busy, exact start payload and
  idempotency key, settlement only on a settled child, `unknown` without retry, waiting without reserved
  capacity and guest import denial. No paid inference.
