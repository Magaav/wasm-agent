# OpenAI subscription

Select **OpenAI subscription** (`openai-sub`) in the model picker, then
`gpt-6-luna`, `gpt-6-sol`, `gpt-6.1-sol`, or `gpt-6-astra`. OpenCode Go remains a separate provider.

## The picker, and the catalogue it is not

The picker list in `lua/core/openai_sub.lua` is what this route *offers* a reader; it is not what
the route can *serve*. The catalogue is pi's local model store,
`~/.pi/agent/models-store.json` (`WASM_AGENT_PI_MODELS_STORE` overrides it), keyed by pi's own
provider id and carrying the `api` each id is served over. Three readers depend on that one file:
`provider.lua` decides servability from it, `model_window.lua` reads context windows from it, and
the bridge resolves from it an id the *installed* pi package predates. pi fills it from
`https://pi.dev/api/models/providers/<pi-provider-id>`.

So an id is usable only when it is in both places: offered by the picker (this repository) **and**
published for `openai-codex` over `openai-codex-responses` in the store (live config). Either half
alone is a model that looks configured and fails - a picked id nothing catalogs, or a catalogued id
nothing offers. The spoken name and the id are different strings (`sol 6.1` is `gpt-6.1-sol`), and
only the id routes: a name the catalogue never mentions stays undecided rather than being guessed.

### Live-config journal

| date | file | exact edit | why |
| --- | --- | --- | --- |
| 2026-09-29 | `C:\Users\Victor\.pi\agent\models-store.json` | appended the `gpt-6.1-sol` entry to `openai-codex.models`, verbatim from `https://pi.dev/api/models/providers/openai-codex`, and refreshed that entry's `checkedAt`, `lastModified` and `etag` from the same response's headers | upstream published `gpt-6.1-sol` after the store's 8-id copy was fetched, so neither the preflight nor the bridge knew the id: it was offered-by-nothing and refused-at-request-time |

Receipts for that row: sha256 `6dc2c6e9…` (38966 bytes) before, `ba4378da…` (40371 bytes) after;
the diff is exactly the added entry plus those three metadata fields, with the other provider's
entries byte-identical. The pre-edit file is kept beside it as
`models-store.json.journal-before-20260929T213726.json`. This is a cache refresh, not a fork of
pi's data: a later pi refresh rewrites the file from upstream, which already publishes the id. The
cross-check that a future reader should repeat is `pi --list-models` - it lists
`openai-codex gpt-6.1-sol 272K 128K` after the edit and listed eight codex ids before it, so the
change is legible to pi's own runtime and not only to wasm-agent. Verified 2026-09-29: one minimal
live request on this route with `gpt-6.1-sol` answered `ok` (28 tokens, 2.3 s).

This route uses Pi's `openai-codex` ChatGPT subscription login and its Responses
adapter, including locked OAuth refresh. Run `/login` in Pi and choose OpenAI
if not already signed in. No OpenAI API key is required. Credentials stay in
Pi's auth store; wasm-agent never copies them into its configuration or commands.

Node and a current Pi installation are required on the machine running the node.
`WASM_AGENT_PI_PACKAGE` can point at the installed `pi-coding-agent` package directory
when automatic discovery cannot find it. `PI_CODING_AGENT_DIR` overrides Pi's agent
directory (normally `.pi/agent` beneath the host's home directory).

The status balloon reads the account's 5-hour, weekly, and monthly quota windows through
Codex's private `/wham/usage` endpoint when the account response exposes them. Pi resolves and refreshes the OAuth token;
wasm-agent keeps the token inside its short-lived bridge process. If the endpoint
or account response changes, the balloon reports limits unavailable.

The bridge runs as a supervised operation: streamed text and reasoning are forwarded,
tool calls return to the Lua agent, and cancellation/deadlines stop the process.
The model window is Pi's subscription catalog's 272,000 tokens, rather than assuming
the public API's larger window. Subscription access still depends on the account.

Risk: this intentionally depends on Pi's installed adapter API and OpenAI's private usage
endpoint. Update Pi to a version whose catalog includes the GPT-6 family; an id the installed Pi
predates still resolves when the store publishes it for this route, and anything else fails
visibly rather than being substituted. Incompatible/missing dependencies fail visibly.
The graph audit does not resolve calls inside the embedded JavaScript string;
the bridge's offline contract test and real subscription exchanges cover that boundary.
