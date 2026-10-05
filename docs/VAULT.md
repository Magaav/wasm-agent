# wa-vault: provider keys the agent can use and cannot read

## Why a separate process

The agent has a shell, and the shell runs as the node's own user. So any key the node can read, the
agent can read too: `env`, `cat`, `/proc/self/environ`, the node's data directory. A key "kept from
the agent" inside the node is a key the agent holds. That covers `WASM_AGENT_LLM_API_KEY` in the
environment, and it covers the subscription store at `<data>/openai-sub/credentials.json`.

The only boundary that holds is a process the agent cannot reach into, with storage it cannot mount.
`vault/wa_vault.py` is that process. Deployed, it runs in its own container with its own volume. The
node never receives a key. A vaulted route sends its request to the vault with a placeholder
(`wa-vault-brokered`) where the credential would be. The vault drops that header, sets the real one,
and streams the upstream's answer back.

The agent can **use** a key: run a turn, or test a provider by calling the route. No endpoint returns
a stored value, so the agent cannot **retrieve** one.

## Turning it on

Set `WASM_AGENT_VAULT_URL` on the node (for example `http://wa-vault:8810`). With it set:

| Route | Goes to | Credential |
| --- | --- | --- |
| `opencode-go` | `$VAULT/opencode-go/v1` → `https://opencode.ai/zen/go/v1` | the API key pasted on the vault page |
| `openai-sub` | `$VAULT/openai-sub/codex/responses`, `$VAULT/openai-sub/wham/usage` → `https://chatgpt.com/backend-api/...` | the ChatGPT login done on the vault page (device code), refreshed by the vault |

Unset, nothing changes: every route reads its key and endpoint as before.

On a vaulted node:

- The vault takes precedence over `WASM_AGENT_LLM_API_KEY`, `OPENCODE_GO_API_KEY` and `WASM_AGENT_LLM_BASE_URL` for opencode-go. A key left in the environment is not used. Remove it, because the agent can still read it there.
- `openai-sub` uses the native wire (`lua/core/subscription_wire.lua`). Its credential seam is `lua/core/vault.lua`, which reads presence from the vault's `/status` and hands the wire the placeholder. An explicit `WASM_AGENT_SUBSCRIPTION_TRANSPORT=pi` is refused, because Pi would need a token this node does not have.
- opencode's attribution rule (`x-opencode-session`) still applies. The profile's `upstream_host` names the service behind the vault route.

## Signing in: `/login`, like pi

In `wa chat`, type `/login`. It lists the providers and their state, then:

- **1. OpenAI subscription.** The vault starts the ChatGPT device login. The CLI prints the link (`auth.openai.com/codex/device`) and a code, then waits. You open the link, sign in and enter the code, and the CLI says "logged in". Press Enter to stop waiting; the code stays valid for about 15 minutes.
- **2. OpenCode Go.** Paste the key at the prompt. The line is not written to the transcript. It goes straight to the vault and is not kept by the node.

Either way, the provider then becomes the active one. The vault page (the operator's side) does the same, and can also remove a credential, disable a provider or test it.

`/login` talks to the vault's node-side door (`/login`, `/login/<provider>` on the proxy listener). Those routes need no admin token, so the agent can reach them as well. It can start a device login, which only a person with the ChatGPT account can complete, or replace the opencode-go key. Like everything else on the vault, those routes are write-only: no answer carries a stored value. Removing a credential stays on the admin page.

Known limit: the pasted key passes through the `wa chat` process on its way to the vault. The line editor's up-arrow history (in memory, per session) also holds it until that `wa chat` exits.

## The vault

Standard library Python, one file. It has two listeners for two audiences:

- **proxy** (`:8810`, the node's side): the fixed routes above, plus `GET /status`. `/status` returns presence only (`configured`, `enabled`, timestamps, account id).
- **admin** (`:8801`, the operator's side): the page (an installable PWA) and its API. Every API call needs `X-Vault-Token`, which is the `WA_VAULT_ADMIN_TOKEN` given to the vault process only. The vault refuses to start without a token of at least 24 characters.

The rules it is built around (the reasons are in the file header):

1. **No read path.** The admin API can write, replace, delete, enable/disable, test and report status. It cannot return a key. A stolen admin token can overwrite a key but not read it.
2. **The upstream is fixed per route.** The caller picks a path, never a host. The Host header is not passed through and redirects are not followed. The subscription route only allows `codex/` and `wham/usage`, so the OAuth token reaches only the two endpoints wasm-agent uses.
3. **The node's credential headers are dropped**, and so are cookie and forwarding headers.
4. **Single-flight refresh.** The refresh token rotates on every use, so refresh runs once under a lock and the store is re-read inside it. A rejected refresh is never retried.

The OAuth client id, endpoints and device-code flow are the ones `lua/core/openai_sub_auth.lua` measured from Pi 0.87.1 (MIT).

## Tests

- `scripts/test-vault-login.lua`: drives `/login` with a scripted reader against a live vault. It checks that the key is stored, is never printed, and that the provider is selected; a cancel stores nothing.
- `python3 scripts/test-vault.py`: runs the real vault against local fake upstreams. It also covers the `/login` door: no token needed, write-only, cannot delete. It checks that the key reaches the upstream and the placeholder does not, that no endpoint or log line carries a stored value, the token gate, the route allowlist, that redirects are passed back rather than followed, SSE streaming, one refresh for five concurrent callers, and the device login end to end.
- `scripts/test-vault-routing.lua`: run once with `WASM_AGENT_VAULT_URL` set and once without (see its header). It checks that the provider, the wire and the transport route through the vault only when the variable is set.

## Risks

- **Same risk as the native subscription wire.** The vault uses the same private ChatGPT endpoints and the same measured OAuth flow.
- **The boundary is the deployment, not this code.** The vault's volume and `WA_VAULT_ADMIN_TOKEN` must stay out of the agent's container. If you run the vault as the node's own user on the same filesystem, the agent can read the store again.
- **The agent can spend the credential.** It can send any request the routes allow. That is the point of "use but not read". Disable a provider on the page to stop it.
