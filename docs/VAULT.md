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

The node and chat **never receive the vault admin token or a replacement key**.
`/provider` opens/prints a separate operator vault page URL. On that origin, enroll using its
password admin-token input; then enter the Go key in its dedicated password field and Save.
Neither input uses chat/composer, terminal editor, general drafts, URL fragments, localStorage,
logs or a credential-readback endpoint. Admin authorization remains in page memory only and is
cleared on page exit. Old persisted-token/fragment enrollment is retired, not adopted.
CLI `/login` no longer asks for keys through the ordinary history-bearing terminal editor.
Use the documented operator browser flow, not a shell argument containing a key/token.

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

Configure the nonsecret operator URL on the node before the user test. The page says which vault
it manages and does not secretly alter the node's auth source. Configuration alone is not proof
that a service exists or the account has allowance. `/provider` reports setup-required/unknown
rather than opening an unsafe secret prompt when the operator route is missing.

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
2. Select OpenCode Go only if desired; choose its operator management link.
3. Enroll on the separate vault origin with the dedicated admin password input.
4. Paste the operator-generated **new Go key** into its password input; Save once and confirm.
5. Read the exact committed outcome; cancel entry or reconcile an unknown outcome rather than
   resubmitting. No model test is performed by Save.
6. Return to chat and explicitly send a new turn when wanted. Same-workspace monthly quota
   may still fail. No previous failed request is automatically replayed.

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
