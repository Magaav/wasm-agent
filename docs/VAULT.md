# Provider management and wa-vault

## Deterministic recovery: `/provider`

Both `wa chat` and the window accept bare `/provider` (`/login` is an alias).
No inference/classifier is used. One management route is listed:

- **OpenCode Go** (`opencode-go`): explicit selection, or operator vault key replacement.

(The ChatGPT-subscription route, `openai-sub`, and the plain `gpt` route were removed on
2026-10-28: neither was used. A `vault.json` entry or `~/.wasm-agent/.../openai-sub/credentials.json`
left by an older build is ignored, and the node still redacts that file's values while it exists.)

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
| `WASM_AGENT_OPENCODE_GO_VAULT_URL` | Broker origin for Go, or `native` to use its legacy environment route |
| `WASM_AGENT_VAULT_URL` | Default broker origin when no per-provider override is present |
| `WASM_AGENT_VAULT_OPERATOR_URL` | Nonsecret browser operator-page origin; never a token-bearing URL |
| `WASM_AGENT_OPENCODE_GO_OPERATOR_URL` | Optional Go operator-page origin |

Source configuration is service/operator-owned and becomes effective through the normal
idle-safe service update, not an in-turn environment edit. Errors never authorize fallback.

Vaulted requests use `wa-vault-brokered`, not a key. Fixed routes:

- `/opencode-go/v1` -> `https://opencode.ai/zen/go/v1`

Caller credential/Host/cookie/forwarding headers are dropped, redirects are not followed.
No endpoint returns credentials.

The **release signing key** (`release-signing`, ed25519) lives here too, and it has no proxy route at all -
every route for it is on the admin listener, so the agents' listener answers 404:

| Route (admin only, `X-Vault-Token`) | What it does |
| --- | --- |
| `GET /api/release-signing` | the key id and the **public** key; never the seed |
| `POST /api/release-signing/key` | generate the key inside the vault (`{"replace":true}` rotates it) |
| `POST /api/release-signing/sign` | `{"sha256": "<hex>"}` or `{"bytes": "<base64>"}` -> signature + key id |
| `POST /api/release-signing/backup` | the ONE offline backup: `{"path": "/abs/file"}` writes it 0600 without overwriting, `{}` shows it once; after either, every call is refused |

One log line per signature (key id and the manifest's sha256, never key material). Why the key is here and
how a node trusts it: `docs/INSTALL.md`, "Signed releases".

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

- proxy (`:8810`): fixed upstreams, presence/generation `/status`, write-only `/login/opencode-go`;
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
The ordinary node door (`POST /login/opencode-go`) can place or replace the Go key and can
never read one; removing a key stays on the operator page.

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

Node management is master-only and local-target-only. Open a remote node's own UI directly;
there is no secret relay to whatever node the picker happens to select. Node/account changes
invalidate the panel's action scope. Guest/child inference has no admin enrollment authority.

## Keys the agent uses but never sees: `/vault <name> <value>`

Provider credentials live in wa-vault, behind proxy routes. Any other key a task needs (a GitHub
token, a service API key) is stored with `/vault`, in the CLI or the window:

- `/vault github ghp_...` in the CLI, or `/vault github` to type the value in a secret panel;
  `/vault` in the window opens a dialog with a password field (`POST /vault/key`, master only).
- The value is written to `~/.wasm-agent/keys/<name>.key`, mode 0600 (`lua/core/keys.lua`;
  `WASM_AGENT_KEYS_DIR` moves the store).
- The model is told the names and the path, never a value, and uses a key by reference:
  `curl -H "Authorization: Bearer $(cat ~/.wasm-agent/keys/github.key)" ...`.
- Every stored value is an exact-value secret for `lua/core/redact.lua`: a tool result that carries
  it (a `cat`, an `env` dump, a verbose curl) is redacted before it is stored, shown or sent.
- The line itself never reaches a model turn, the transcript (the CLI echoes `/vault <name> ••••`),
  the editor's history, steering, or the window's saved draft.

This is not wa-vault's isolation: the agent's shell runs as the same user and *can* read the file.
The redaction is exact-value, so the value as stored never reaches a transcript or a provider; a
transformed copy (base64, split, reversed) would not be recognised, and a command can still send
the key wherever the command sends it. Keys that need real isolation belong behind a wa-vault route.

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

### A test fixture is never answered by the operator's vault

The vault wins over `WASM_AGENT_LLM_BASE_URL` and every other provider variable on purpose (see
"Credential sources" above), so a test process that inherits `WASM_AGENT_VAULT_URL` is routed to the
operator's real provider no matter what endpoint its fixture named. Measured on a node (11/11,
speed.log): a fixture set a dead port as its base URL, the child inherited the session's vault URL, and
the call went to the operator's provider with their credentials - `reasoning text looks like a real
model` was the only clue.

Three rules, each with the row that enforces it:

- **The runner removes the variables.** `scripts/fast.sh` unsets `WASM_AGENT_VAULT_URL`,
  `WASM_AGENT_VAULT_DIR`, `WASM_AGENT_VAULT_KEYSTORE` and `WASM_AGENT_VAULT_PASSPHRASE` before any row,
  cargo test or node check is spawned, and hands the names to each Lua row as `WA_FAST_CLEARED`.
  `scripts/test-fast-row-environment.lua` fails by name if a row still sees one - the promise is checked
  from inside the node, not trusted in the runner.
- **A fixture clears them itself.** `scripts/lib/test-provider.lua` installs a getenv that always answers
  nil for every vault variable, then the fixture's own values, then the real environment; in JavaScript,
  `delete ENV.WASM_AGENT_VAULT_URL` (and the sibling names) on the child's environment, as
  `scripts/test-cli-scripted.mjs` does.
- **A row reached by hand refuses.** Run inside a node session, a fixture row sees a vault; then
  `test-provider.lua`'s `refuse_vault` fails it with `fixture_provider_vault_url` naming the variable and
  the runner, instead of passing quietly on the operator's provider.

`scripts/test-fixture-provider-isolation.lua` proves the precedence itself through the real provider and
vault modules - the leak with a passthrough getenv, the cure with the fixture getenv, the refusal by name.

## The vault as a component: `wa vault` and the kernel keystore

The rest of this document is the *provider* vault (`wa-vault`, a separate service behind fixed proxy
routes). This section is the other half of the same idea, built for "everything as a component" on WASI
0.3: a **vault component** that holds the operator's secrets, signs with the fleet's ed25519 key, rotates,
revokes and keeps a hash-chained audit - and a **kernel keystore** that is the only thing holding a key.

### Two capabilities, and neither of them is a key

| where | code | what it may do |
| --- | --- | --- |
| the kernel, in-process | `rust/wa-keystore` (`wa:kernel/keystore`) | create/wrap/unwrap the root data key; `seal`/`open` a blob under a **namespace** the host binds and a `context` that becomes the associated data |
| the vault engine | `rust/wa-vault` | entries, rotation, audit, ed25519 signing - it never sees the root key, only `seal`/`open` |
| the operator's terminal | `wa vault ...`, `rust/wa-vault/src/cli.rs` | the same engine, over 0600 files in the vault directory |

The root key is 32 bytes, created once per vault directory and stored **wrapped** by the strongest
protection the host has, in this order: Windows **DPAPI** (user scope, `CryptProtectData`, no passphrase,
no prompt), the **Linux kernel keyring** (`add_key`/`keyctl` in the user keyring; the file then holds an
XChaCha20-Poly1305 blob only that key opens), or - where neither is available, e.g. a restricted container
or an unsupported architecture - a 0600 file sealed with a key derived by **Argon2id** from an operator
passphrase (`WASM_AGENT_VAULT_PASSPHRASE`). Which one is in use is reported, never assumed: `wa vault
status` prints `protection: dpapi|keyring|passphrase`, and an unknown `WASM_AGENT_VAULT_KEYSTORE` value is a
refusal rather than a silent downgrade. **TPM 2.0 is not wired**: no `tpm2`/`tss-esapi` crate builds
offline on this toolchain, and a TPM path that fell back to DPAPI without saying so would be worse than the
gap. It is a later row, not a claim.

A component is given `seal(context, plaintext)` and `open(context, sealed)` and nothing else: no key
material crosses the seam in either direction, and the namespace is not an argument (the kernel binds it
before the interface is linked). That is what makes "the root key never leaves the kernel" true at the
interface rather than only in the prose.

### Entries

An entry is `name -> value`, `value` sealed with **XChaCha20-Poly1305**, a random 24-byte nonce per version
and AAD `vault-entry-v1|<kind>|<name>|<version>`. Metadata - `kind: secret|ed25519`, `version`, `created`,
`rotated_at`, `owner` (`kernel` or `operator:<name>`), `allowed` (actor ids that may sign) - is what `list`
answers; a value is not in it, and `list` has no field a value could ride in.

| operation | who may call it | what it answers |
| --- | --- | --- |
| `set` / `rotate` / `delete` / `import-ed25519` | the kernel, the operator | metadata |
| `list` / `show` | anyone allowed to talk to the vault | names and metadata |
| `use_by_ref` | **the kernel only**, no grant exists | the value, for one credential header |
| `reveal` | a component **only** with a `vault.reveal` grant naming it and the entry; kernel and operator are the vault's owners | the value |
| `sign` | a `kind: ed25519` entry, for the owner, the kernel, or an actor in `allowed` | a 64-byte signature |
| `public-key` | anyone | the public half (public data) |

`sign` is the only operation that opens an ed25519 seed, and it opens it for the length of one signature.
There is no `export`: an entry of kind `ed25519` cannot be turned back into a file through this vault.

**Rotation** writes a new live version (a new nonce, a new version in the AAD) and keeps the previous one
readable until `rotated_at + window` (default 7 days, `VaultOptions::rotation_window_s`). After the window
`purge_expired` **destroys** the old material rather than hiding it - at open, and on the next rotate - and
records a `destroy` line in the audit. A client pinned to the old generation keeps working through the
change; the operator can prove what happened afterwards.

### The audit chain

Every operation appends one line, and every line is a link:

```text
vault-audit-v1|<prev_hash>|<seq>|<ts>|<actor>|<op>|<name>|<version>|<result>
```

`hash` is SHA-256 of exactly those bytes, `prev_hash` is the previous line's hash, and the document keeps
`audit_head` (the last hash) so a **truncated** log is caught as well as an edited one. `seq` is 1-based
and must increase by one, so a deleted line is caught on the next line. The fields are names; `result` is
`ok` or `refused:<reason>`; the one `ok:` payload is the **public** key an `import-ed25519` produced.
`wa vault audit verify` recomputes the whole chain from the file and exits non-zero with the reason
(`audit_hash_mismatch:2`, `audit_seq_out_of_order:2`, `audit_head_mismatch`).

### `vault.reveal`, and the link-time half

```json
{ "vault": { "reveal": [ { "component": "wa-email", "entry": "smtp-password" } ] } }
```

Only the `vault` section is read here, and it is parsed strictly: `{"vault": {"reval": [...]}}` is an error
instead of a policy that silently grants nothing. `entry: "*"` is allowed; `component: "*"` is not
special-cased - write the component's name.

The policy is the *runtime* half. The link-time half is the tier table (`docs/WASI-INTERFACES.md`):
`wa:vault/reveal` is tier **C**, so a component that imports it is refused before it runs, whatever its
manifest says and whatever the policy grants. The reveal *interface* therefore names its own door in the
artifact's imports.

### Commands

```text
wa vault status | list | show <name> | set <name> [--kind secret|ed25519] [--from <path>|--stdin]
wa vault rotate <name> [--from <path>|--stdin] | delete <name> | reveal <name>
wa vault public-key <name> | sign <name> [--from <path>|--stdin]
wa vault import-ed25519 <name> --from <path> [--shred]
wa vault import-provider-keys --from <keys-dir>
wa vault audit verify | audit tail [--lines N]
```

`wa` dispatches these itself (`rust/wa-host/src/main.rs` → `wa_capabilities::vault_cli::run_node`),
*before* the database, the graph index, the Lua interpreter and the ripgrep install are touched: a node
whose Lua tree is broken or whose database is locked still answers `wa vault list`. Until that
`command == "vault"` arm existed (it did not until 09/11, while the engine had shipped on 7f6a711b)
every node answered `unknown command: vault` and nothing was ever stored.

Two rules: a **value is never an argument** (only `--from`/`--stdin`, because a shell history, a process
listing and a terminal scrollback are all places a secret is copied to for free), and **only `reveal`
prints a value**. The directory is `--dir`, else `WASM_AGENT_VAULT_DIR`: the node binds the latter once at
startup to `<home>/.wasm-agent/vault`, so `wa vault …` and `wa fleet … --key vault:<name>` open the same
vault and neither guesses. The standalone `wa-vault` binary does not bind it and refuses an unset
directory, so a binary run from the wrong place cannot reach a vault by accident.

`import-ed25519` reads the file an operator actually has, and says which form it read: 32 raw bytes
(`raw-seed`), 64 hex characters (`hex-seed`), or the **pkcs8 hex** that `wa fleet keygen` and `node.key`
write (`pkcs8-hex`). A pkcs8 document's seed is accepted only when it re-derives that document's public
key, so an unrelated 32-byte window cannot be mistaken for it. The source file is **kept** unless
`--shred` is passed; then it is overwritten with zeros and removed *after* the entry verified, and the
command says plainly that on an SSD or a copy-on-write filesystem the original blocks may still hold the
bytes. The chain records the shred (`shred-source`, `wa vault audit tail`), which is the only place an
operator can read afterwards that the file is gone.

### Migration, and the fleet key

`wa vault import-provider-keys --from <keys-dir>` (and the node's first start) reads `*.key` files and puts
each one in the vault: a name that is already there **with the same value** is `kept` (that is what makes a
second start a no-op), a name that is there **with a different value** is `refused` and never overwritten,
and the source file is never touched. The node overlays the vault's answer for the granted `file_env` names
on top of the file's (`wa_kernel_runtime::vault_host::overlay_run_secrets`), so a migrated or rotated key
wins over a stale copy and a node with no vault behaves exactly as before.

The **fleet key** can live in the vault: `wa vault import-ed25519 fleet --from <fleet.key> --shred`, then
`wa fleet sign|revoke|rotate|anchor ... --key vault:fleet` (`docs/MESH.md` §1) signs with the seed that never
leaves the vault. Rotating the fleet key is `wa fleet rotate`; the old key is destroyed with
`wa vault delete` **after** every node confirms the new one.

### What integration needs (the WASI 0.3 / wasmtime 50 upgrade)

* `wa:kernel/keystore` is tier B with `"keystore": true` in the manifest and is **not linkable yet**
  (`served: no` in the table): the host function lands with the 0.3 component runner, together with the
  vault component's own world (`world vault-component`, which needs `wit/vault/vault.wit` reachable from
  `wit/kernel-v2` - a copy in `deps/` or a deps directory, and a doc-table row of its own).
* The engine must be `wasm32-wasip2`-clean before a component body can run it. `ring` is not, so `sign`
  needs `ed25519-dalek` (pure Rust) inside the guest, or - better - `sign` moves behind
  `wa:kernel/keystore` so the seed never enters a component at all. `rust/wa-vault` is host-side today on
  purpose; `REPORT.md` records this as the open decision.
* `wa vault` is dispatched by `rust/wa-capabilities::vault_cli::run_node` from `rust/wa-host/src/main.rs`
  (landed 09/11, with `rust/wa-host/tests/vault_cli.rs` proving the round trip, the fleet signature and
  the keystore refusal through the real binary).
* **No node installs `components/vault.wasm` yet, and the deploy does not look for one.** Every vault
  operation a node answers today runs the host-side engine in `rust/wa-vault` (the CLI above, and
  `wa_kernel_runtime::vault_host` for a run's credentials-by-reference). An installable component needs
  three things this stream could not honestly produce: a guest-clean `wa-vault` (the `ring` split above,
  plus `wa-keystore`/`wa-vault` being buildable for `wasm32-wasip2` - `wa-keystore` is outside the edit
  set of this work), the linkable keystore host function, and a pin in `components.lock` made from real
  bytes on the machine that builds components. Adding the name to `components.lock` without bytes, or to
  the deploy's required list, would fail every deploy that cannot reach the new release bundle (the
  bundle's tag is the lock's sha), so deploy was left alone: the recipe is in `REPORT.md`.
* `wa fleet revoke|rotate|anchor` do **not** push: `wa fleet push-roster` stays the per-node act
  (`docs/MESH.md` §7), so a change is reviewable before it reaches a node.
