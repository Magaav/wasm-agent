# First external release contract

## Scope and ownership

The product supports **personal use** and **operator-assisted automation**. Neither
requires knowing the implementation stack. Assisted users connect a guest device
to a named automation provider; the provider uses its own arsenal to help with
approved tasks. Assisted enrollment is a first-class release track, not permission
for automatic remote access.

Start Windows x64-first, retaining the Rust/Lua runtime, existing configuration,
UI, node/relay fabric, skills, spells and external supervision. No runtime rewrite,
new configuration format, new UI framework or 32-worker requirement.

Two independently gated delivery stages:

1. **Personal preview:** independently installable and useful with the user's
   model. Remote customer enrollment remains unavailable until stage 2 passes.
2. **Assisted pilot:** one authorized operator and two isolated disposable
   customer environments before real customer invitations.

A package can exist without either stage passing. A checksum is not a security
review, a build is not an install test, and a signature is not customer consent.

The human owns scope, customer approval, merges and publication. Implementation
lanes own bounded files; an independent verifier owns the candidate verdict.
Current assignments and evidence belong in [RELEASE_STATUS.md](RELEASE_STATUS.md).

## Required journeys

### Personal

Install without developer infrastructure → friendly agent name → own compatible
model → workspace and authority explained → real tool-backed task → inspect
tracked diff → remember a random marker → restart → recall in a new conversation
→ restore tracked file bytes. Refuse undo when the file has changed again.

### Assisted

Install → choose help from an operator → verify invitation/operator → review
access, data flow and cost responsibility → explicitly approve → connect guest
outbound → operator completes one useful automation → customer reviews evidence
→ disconnect/revoke → old authority cannot act again, even after restart/retry.

The guest does not inherit operator model credentials or require its own key for
operator-driven tool execution. State the execution location of each tool and
reasoning request. Network failure must not silently move work or broaden access.

## Gates

All gates begin **unverified** until linked evidence exists for the exact candidate.

| Gate | Required evidence |
| --- | --- |
| Artifact integrity | One source commit, recorded build target, complete file inventory, SHA-256 checks, rejected missing/changed/extra assets. A trusted distribution path authenticates the publisher separately. |
| Independent installation | Clean Windows user, no Git/Rust/SSH/checkout or inherited config; private developer host unavailable. Required WebView2/runtime prerequisites detected. All UI assets available from the same package. |
| Configuration | Masked credential input; no keys in argv, logs or exports; own provider configuration; bad credentials recoverable; rerun preserves keys/identity, memories and sessions. |
| First useful result | Requested effect actually exists, successful tool result is persisted and terminal outcome is recorded. A version banner or nonempty answer is insufficient. |
| Continuity | Unpredictable harmless memory marker persists across process restart and is retrieved in a new session. Conversation recovery and new-session behavior are distinct. |
| Accountability | Actual diff is displayed; tracked undo restores exact bytes; conflicting later edits are preserved. Clearly exclude arbitrary external effects from undo guarantees. |
| Local authority | Missing/invalid credentials and disallowed origins/hosts fail on sensitive routes. Worker changes do not change roles. No public bind by default. |
| Conversation isolation | Distinct and identical conversation IDs under concurrent requests, different login tokens, overlapping SSE streams and relayed events; no event/transcript mixing or simultaneous same-conversation writers. |
| Enrollment (assisted) | Single-use expiring invite, pinned operator identity, visible customer consent; decline/reuse/expiry/wrong operator are refused without side effects. Discovery and self-declared role alone never authorize. |
| Customer isolation (assisted) | Two customer environments; no cross-customer node listing, tasks, memory, credentials, transcripts, replication or tool authority. Operator receives only authorized data. |
| Revocation (assisted) | Pause and local revoke stop future dispatch; queued/replayed/reconnected work is checked again. Restart preserves revocation. In-flight cancellation limitations are explicit and verified per capability. |
| Recovery | Missing assets, provider outage, tool failure, interruption and reinstall/update produce visible states, not silent success or lost work. Schema rollback compatibility and backup restoration are documented and tested. |
| Lifecycle | Existing installs upgraded only through the external lifecycle gate. No image-name kills, live executable overwrite or window replacement. Fresh-install procedures must not mutate an existing installation. |
| Usability | Unfamiliar users complete the supported journey from public instructions without private fixes. Record interventions; safety/data-loss failures block regardless of completion count. |

Scoped permissions must be enforced where effects occur. A prompt restriction,
workspace selector or WASM plugin boundary does not confine arbitrary native shell
and desktop actions. Until confinement exists, disable those actions or clearly
obtain the intended broad, time-limited authority; do not label it sandboxed.

## Packaging slice

`scripts/package-windows.ps1` builds a candidate from a clean Git checkout using
locked offline dependencies. It assembles only an allowlisted set of runtime files
and writes a manifest and archive checksum. It never copies user state, secrets,
maintainer instructions, or the legacy SSH installers. It neither publishes nor
installs, changes PATH, enrolls a node, or starts/stops a process serving users.

`scripts/test-release-package.ps1` verifies candidate structure and hashes without
executing packaged code. `scripts/test-release-tools.ps1` mutation-tests that
verifier with synthetic bytes. Those checks prove **integrity mechanics only**.
The manifest explicitly says `candidate-unverified`; it does not award a release
verdict or claim reproducible builds.

Candidate commands (not public onboarding):

```powershell
powershell -File scripts/package-windows.ps1 -Version 0.1.0-alpha.1
powershell -File scripts/test-release-package.ps1 -PackagePath dist/wasm-agent-0.1.0-alpha.1-windows-x64
powershell -File scripts/test-release-tools.ps1
```

Full verification must use extracted archive bytes outside the repository, a
scratch user/home/database/ports and no `WASM_AGENT_LUA_ROOT` or `WA_SCRIPT`.
Do not let those tests reuse the live ledger, node keys or operator configuration.

The candidate contains no public installer or setup wizard yet. Do not promote
manual launch instructions to a claim that first-run onboarding is complete.

## Evidence format

```text
Gate / task:
Source commit:
Candidate archive SHA-256:
Platform / prerequisites:
Action / exact command:
Expected assertion:
Actual result: PASS | FAIL | BLOCKED | NOT RUN
Evidence path:
Human intervention / remaining limitation:
```

Retain full private evidence separately from redacted distributable reports.
Record skipped tests as skipped, not passed. Re-verify after integration changes
the candidate bytes. Never tag, publish, deploy or contact customers without the
human's explicit authorization.
