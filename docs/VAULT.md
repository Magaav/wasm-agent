# Provider management and wa-vault

## Deterministic recovery: `/provider`

Both `wa chat` and the window accept bare `/provider` (`/login` is an alias).
No inference/classifier is used. Only these management routes are listed:

- **OpenAI subscription** (`openai-sub`): explicit selection, or confirmed device re-login.
- **OpenCode Go** (`opencode-go`): explicit selection, or operator vault key replacement.

Opening management changes neither account nor provider and never replays a failed turn.
Selection uses the existing persisted settings revision; subsequent turns see the change.
The window refuses selection/auth actions while its run is active. Runs pin their credential
source/generation; if a credential is replaced between rounds, a stale-generation request
fails before upstream dispatch rather than silently sending context to a new account.
An already-dispatched request may finish with its original credential.

Configured/enabled/source/error/unknown are distinct. Presence is **not entitlement proof**.
`GoUsageLimitError` with `limitName=monthly` is account/workspace monthly quota, not evidence
of an invalid token or a transient failure. A new key from the same exhausted workspace may
still fail. This feature does not reset quota, clear serving blocks, compact context, switch
models/providers, probe inference or retry quota automatically. The operator generates/enters
new keys, not an inference agent. Existing provider-serving recovery remains explicit; see
[PROVIDER-SERVING.md](PROVIDER-SERVING.md).

## Credential sources (independent per provider)

| Variable | Meaning |
| --- | --- |
| `WASM_AGENT_OPENCODE_GO_VAULT_URL` | Broker origin for Go only, or `native` to use its legacy environment route |
| `WASM_AGENT_OPENAI_SUB_VAULT_URL` | Broker origin for subscription only, or `native` to retain native auth |
| `WASM_AGENT_VAULT_URL` | Backward-compatible default for **both** routes when no per-provider override is present |
| `WASM_AGENT_VAULT_OPERATOR_URL` | Nonsecret browser operator-page origin; never a token-bearing URL |
| `WASM_AGENT_OPENCODE_GO_OPERATOR_URL`, `WASM_AGENT_OPENAI_SUB_OPERATOR_URL` | Optional per-provider operator-page origins |

Moving Go does not require changing the global variable or copying subscription tokens.
Without a global vault setting, configuring only Go leaves subscription native. If a global
setting already exists, explicitly set the subscription override to `native` only as an
operator-directed source choice. Do not change a working subscription source implicitly.
Source configuration is service/operator-owned and becomes effective through the normal
idle-safe service update, not an in-turn environment edit. Errors never authorize fallback.

Vaulted requests use `wa-vault-brokered`, not a key. Fixed routes:

- `/opencode-go/v1` -> `https://opencode.ai/zen/go/v1`
- `/openai-sub/codex/responses`, `/openai-sub/wham/usage` -> exact ChatGPT backend paths

Caller credential/Host/cookie/forwarding headers are dropped, redirects are not followed.
No endpoint returns credentials. Subscription refresh remains single-flight with its durable
`refresh_pending` no-replay fence. A vaulted subscription refuses the legacy Pi transport.

## Operator enrollment and secret entry

The node and parent app **never receive the vault admin token or a replacement key**.
The GUI now embeds a vault-owned, cross-origin password/enrollment box **inside the
OpenCode Go section of `/provider`**, replacing its former external-link-only workflow
at the human's explicit request. CLI management still prints the separate operator-page
URL instead of using its history-bearing terminal editor. No missing-service fallback
accepts a key in parent DOM, chat, configuration or native environment.

Only `GET /embed/go` is frameable, and only by the exact configured
`WA_VAULT_EMBED_PARENT_ORIGIN` (HTTPS, or explicit operator loopback HTTP). The full admin
page retains `frame-ancestors 'none'` and `X-Frame-Options: DENY`. The dedicated document
uses a restrictive self-only CSP, `form-action 'none'`, and a script/same-origin/forms
sandbox without navigation/popups. `allow-forms` is needed for browser submit/Enter events;
handlers prevent default and CSP denies every navigational form submission. Writes use only
fixed same-origin fetch endpoints. No wildcard CORS or parent-origin API credential relay exists.
The actual iframe source must be a different HTTPS/loopback origin at `/embed/go`.
Its bootstrap verifies the expected vault identity and exact parent against `/embed/config`
before accepting any input. Public identity/scope/channel values in the frame fragment
are **not credentials**; no key or admin token ever belongs in a URL or fragment.

Enroll privately with the labelled password token input, then paste the operator-generated
Go key in the labelled password key input and click **Save to vault**. Both secrets stay
in the vault frame's transient memory, never parent events, drafts/undo, WebStorage, logs,
model/tool arguments, clipboard helpers or credential-readback APIs. Cancel/close/scope
change clears fields; success clears the entered key. Enrollment is memory-only and must
be repeated after closing/reloading the frame. SOP prevents parent JS access, not a
compromised operator browser/debugger, hostile extensions, parent phishing or unrestricted
same-user OS access; the durable storage isolation prerequisite remains essential.

The parent grants each save intent only after current node/account/master/busy checks and
a fresh matching broker/source/identity/generation read. It validates the actual
postMessage source window, exact origin and per-frame channel plus a stable public
node/account scope (hash of public node ID and account ID, **not an auth token**).
A frame's `committed` message alone is never proof: parent rereads the actual route's
opaque current operation and generation and must match both. No message contains a key,
admin token, provider error body or credential-derived hash. A late old-scope reply cannot
act on a newly selected account/node. Opening/saving never selects a provider or probes inference.

The vault has separate listeners:

- proxy (`:8810`): fixed upstreams, presence/generation `/status`, **first-login only** `/login`;
- admin (`:8801`): page plus token-authorized write-only API. At least 24 token characters are
  required at startup. No admin token belongs in the node/model environment or configuration.

Browser API requests must have the exact `WA_VAULT_ADMIN_ORIGIN`; the default is
`http://127.0.0.1:<admin-port>`. Configure the exact HTTPS origin behind a production reverse
proxy. Foreign/stale origins refuse even with a token; no CORS/redirect workaround is supplied.
Nonbrowser operator clients still need `X-Vault-Token`. The primary management link carries
only a public opaque vault identity (never a credential). Before showing enrollment fields,
the operator page checks its public `/identity` against that expected vault. Operator API
requests bind the observed instance as well as origin/generation. Migration verifies that
proxy and operator origins identify the same durable vault before sending authorization or
a key. A stale/wrong instance refuses rather than becoming a different account/source.
The ordinary node door cannot replace
existing keys/logins or cancel an existing operator subscription login.

The embedded form additionally uses `/api/embed/go/{prepare,save,state,cancel}` on the
vault admin origin. All require operator authorization, exact vault identity and a typed
public scope. Prepare durably fences a UUID operation **without the proposed key**; Save
atomically commits the credential plus operation/generation under the store lock once.
The durable nonsecret ledger survives reload/restart, so no browser storage is needed.
Transport can redeliver a request: the backend refuses a second save for that operation.
A conflict response alone does not prove the original outcome; exact operation readback
is required. There is no JavaScript credential retry loop or automatic new save intent.
Unknown sends hold Save disabled. Read status reconciles the exact historical operation;
explicit Cancel fences late sends only if not already committed, otherwise reports commit.
Closing does not cancel/retry a write. Superseded/stale operations are not success-looking.
At 1024 retained operations, preparation refuses for operator review instead of deleting
unknown evidence. The proxy exposes only the opaque *current* Go operation/generation for
parent readback, not ledger history or credentials. This is not a credential readback API.

Go Save carries an opaque operation ID and the observed credential generation. The store checks
and mutation share one lock. A stale/concurrent save refuses; success is reconciled using the
**exact operation and generation**, not presence. A lost response disables another Save until
status reconciles that operation. An unresolved/superseded result is not success and is never
automatically replayed. Removal is generation-checked and leaves an opaque tombstone.

Subscription re-login retains the existing usable credential until fresh human-completed login
commits. Cancellation/failure does not delete it; cancelled/superseded flows cannot resurrect.
Native UI/CLI use the existing device endpoints via an operator-scoped nonblocking flow with
single-flight locking, an authorization-exchange fence and opaque outcome reconciliation.
Use **Check device completion**, **Reconcile outcome**, or **Cancel device login** explicitly.
Closing the panel is not cancellation. The pending opaque operation survives a page reload in
sessionStorage; credentials do not. Native and vault auth stores are never copied between one
another. A source transition requires an explicit operator configuration plus fresh login.

Node management is master-only and local-target-only. Open a remote node's own UI directly;
there is no secret relay to whatever node the picker happens to select. Node/account changes
invalidate the panel's action scope. Guest/child inference has no admin enrollment authority.

## Production prerequisites (coordinator/operator only)

Provision a **durable isolated** vault service from this source (`python vault/wa_vault.py`, or
`vault/Dockerfile`), a private persistent volume, proxy reachability from the node, and an
operator-only admin listener/HTTPS origin. Supply `WA_VAULT_ADMIN_TOKEN` through the vault's
private service secret configuration, never through the node or model. The runtime/volume/admin
secret must not be readable/mountable by the agent. Same-user Windows files/ACLs are **not** a
strong isolation boundary. A local synthetic fixture is not a production deployment.
Do not reuse a disposable benchmark service/store. Live service discovery/provisioning,
credential migration, restarts and installed UI publication belong to the coordinator.

Configure the nonsecret operator URL on the node and the exact parent browser origin on
this isolated vault service before the user test. Example nonsecret configuration:

```text
# NODE service (explicitly approved Go route only)
WASM_AGENT_OPENCODE_GO_VAULT_URL=<fixed-proxy-origin>
WASM_AGENT_VAULT_OPERATOR_URL=<separate-operator-admin-origin>
# VAULT service only
WA_VAULT_ADMIN_ORIGIN=<exact-admin-origin>
WA_VAULT_EMBED_PARENT_ORIGIN=<exact-node-browser-origin-no-trailing-slash>
```

Keep `WA_VAULT_ADMIN_TOKEN` in private vault service secret configuration, not these node
settings or command arguments. Proxy/admin origins must independently prove the same
persistent `/identity`; expose `/embed/go`, `/embed/config`, `/embed-go.js` and `/embed-go.css`
through the exact admin HTTPS origin without redirects, not through the node. This supports
one explicitly configured embedding parent per deployment. A framing/TLS/identity/source
failure is visible and disables entry; it is not permission to relax origins or copy tokens.
The worker does not provision/register services or bypass unavailable cloud capabilities.
An authorized isolated/cloud operator terminal may be required for actual deployment.

## Guarded Go migration (operator-only helper)

**Do not run against live credentials from an inference worker.** Run in the authorized operator
context, with the same effective service environment and the actual configured env source.
The helper mirrors native per-variable process-over-file loading and Go alias precedence:
`WASM_AGENT_LLM_API_KEY`, then `OPENCODE_GO_API_KEY`, then `OPENAI_API_KEY`. File parsing matches
`wa-host`'s first-entry, trim/quote-edge contract, not shell expansion. If a service launcher uses
another `.env`, explicitly supply that actual source and its effective exported environment.
The operator must confirm the intended Go source; non-Go upstreams refuse import.

Use public origins/paths only (replace placeholders; no secret command-line values):

```text
python scripts/migrate-go-vault.py --check --env-file <actual-env-file> --vault-url <proxy-origin>
python scripts/migrate-go-vault.py --apply --confirm-go-source --env-file <actual-env-file> --vault-url <proxy-origin> --admin-url <operator-origin> --journal <private-nonsecret-journal.json>
python scripts/migrate-go-vault.py --reconcile --confirm-go-source --env-file <actual-env-file> --vault-url <proxy-origin> --admin-url <operator-origin> --journal <same-journal.json> --node-url <actual-node-origin>
```

`--check` returns only source path/variable name/presence, route and readiness metadata.
Apply prompts through `getpass` for operator authorization, refuses an already-configured vault,
persists a nonsecret `sending` journal before its one key write, reads exact operation/generation,
and configures **only Go's** vault origin. It retains all legacy key entries at this stage.
No plaintext backup is made. An unknown send leaves the original source and journal intact;
run reconcile, never rerun apply or delete its journal to retry.

After an idle-safe coordinator service configuration/update makes that route effective,
reconcile prompts privately for vault authorization and (if needed) the node UI session.
It requires exact node source/URL/generation readback and unchanged source-file identity/stamps
before retiring dedicated Go file aliases. Changed/stale/unknown evidence refuses deletion.
`OPENAI_API_KEY` is generic and is **never deleted implicitly**; process/service environment
aliases cannot be deleted by a file helper. The coordinator must explicitly retire those after
verification and confirm that unrelated providers do not need them. Do not claim plaintext
retirement until both file and service/process sources are actually retired.
The journal contains opaque IDs and nonsecret source metadata, never values or key hashes.
Source stamps protect accidental concurrent edits, not a malicious same-user attacker.

## User test after coordinator installation/setup

1. Type `/provider`; verify both friendly routes and actual source/state.
2. In OpenCode Go's embedded private box, verify destination origin/vault identity; select Go separately only if desired.
3. Enroll using the box's dedicated private operator-token password field.
4. Paste the operator-generated **new Go key** into the box's password key field; click **Save to vault** once.
5. Read the exact committed outcome; cancel entry or reconcile an unknown outcome rather than
   resubmitting. No model test is performed by Save.
6. Return to chat and explicitly send a new turn when wanted. Same-workspace monthly quota
   may still fail. No previous failed request is automatically replayed.

`python scripts/test-vault-embed.py` adds real HTTP durable prepare/save/cancel/restart,
origin/CSP/authorization/scope/CAS and ambiguous-send proof. `node
scripts/test-provider-inline-browser.cjs <fresh-evidence>` adds the actual staged parent plus
real cross-origin frame/HTTP interaction, synthetic paste/save, parent non-disclosure,
forged/stale events, scope/busy/close/reload, TLS/identity/setup refusal and old-UI causal
negative. This is synthetic functionality proof, **not live secure provisioning**.

## Focused synthetic proof

`python scripts/test-vault.py` uses real vault HTTP/fake upstreams, first-login/operator/CAS/
origin boundaries, no-readback, refresh/no-replay and private env migration/reconciliation.
`scripts/test-provider-management.cjs <candidate>` and
`scripts/test-provider-recovery-regressions.cjs <candidate>` run source + standalone embedding,
CLI/device/scope/generation/cancel/unknown and existing auth/recovery contracts in private homes.
`scripts/test-provider-management-ui.cjs <fresh-evidence>` renders both staged surfaces in real
Chromium, checks password/cancel/single-flight/no-persistence/error and a causal negative.
Then run `scripts/test-ui.ps1` once after focused UI passes and inspect screenshots.
No paid provider call, actual account login, live migration or release gate is implied.
