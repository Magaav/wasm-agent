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

## Stream diagnostics and visible reconnect cycles

The Pi bridge observes fetch below Pi's error normalizer: response-header/body
stage, bounded redacted cause chain/code, HTTP status, safe request ID, response
byte count, EOF and whether any model progress occurred. No request URL/header,
body or streamed-text payload is copied into these diagnostics. Error messages use
bounded heuristic redaction, not a universal secret-scrubbing guarantee; keep logs private.
`subscription_transport` attempt/retry events are durable; raw operation results
remain the execution evidence. Reader cancellation propagates to the real stream.

`WASM_AGENT_SUBSCRIPTION_TRANSPORT_RETRIES=10` is the default (integer0..10;
0 disables). A cycle makes up to10 reconnect attempts over60s after a recognized
pre-output Node transport failure. Header establishment is bounded by the remaining
cycle slot; HTTP200 connection establishment removes that reconnect timer, so
healthy model thinking is not mistaken for a failed connection. Real body-read
failure before model progress can still recover. Known `thinking_start`/`text_start`
events are NOT output only when their typed partial snapshot contains exclusively
verified empty text/thinking blocks. Their counts and exact safe event class are
recorded. The same distinction applies to Pi's normalized failed result: an array
of known empty blocks is not generated output. Missing/malformed/nonempty/unknown
blocks and unknown progress suppress the pre-output replay path, as do
auth/quota/non200, cancellation and unclassified errors. A future adapter event
never gains replay authority by being invisible. Pi's internal maxRetries is0;
broader Lua policies cannot multiply recovery.

### Regenerating an interrupted response within the run

The production Lua caller now explicitly grants the bridge `midstream_recovery`:
recognized transport failures can also regenerate known provisional text/thinking
and function-call output, even after a tool item ends, because **the bridge cannot
dispatch tools**. Only a successful complete result reaches the agent's transcript
commit and dispatch boundary. Earlier rounds' completed tools remain in context
and never execute again. Unknown adapter events, unknown/malformed block shapes,
server/custom tool shapes, auth/quota/non200, cancellation and unclassified errors
still refuse. This is regeneration from the last committed request, not byte-level
resume or exactly-once provider inference.

Before retry, a durable `role:retry` row retains full abandoned text/reasoning and
bounded argument previews with `tools_executed:0`; the supervised operation retains
original output. Transport diagnostics exclude generated text. The renderer marks
the abandoned output interrupted/not executed, seals its preview state, and keeps
each new attempt's text IDs distinct. It never silently overwrites the old evidence
or mixes partial arguments into a new completed call. Nonstreaming callers have
the same execution boundary. No prior installer, send or tool result is replayed.

The existing ten-attempt cycles, cooldown and original deadline still apply; retries
can be disabled with the existing environment setting. Persistent outages can fail;
regeneration may compute/bill inference twice and may produce a different answer.
These risks do not authorize replay of external effects or deleting history.
Focused paired proof: `scripts/test-subscription-midstream.cjs <built-wa> <fresh-evidence>`
then `--post`; the actual agent loop checks one regenerated write, earlier completed
tools, interrupted commentary/final text, normalized Pi failure, unknown shapes,
cancellation and disabled retry. A private old-policy mutation must fail. No paid
provider calls or full release certification is implied.

Focused proof: `node scripts/test-subscription-empty-start.cjs <absolute-built-wa>
<fresh-absolute-evidence>` runs both disk and embedded Lua and a private mutation
restoring the old start classification.389 assertions passed with zero skips,
including actual Lua/operation recovery after empty starts; the old-policy mutant
fails. `--post` verifies retained source/binary/log hashes without replay. This is
candidate evidence, not a claim that the installed older binary already retries.
See [measurements/subscription-empty-start-20261008.json](measurements/subscription-empty-start-20261008.json).

After10/10 or the cycle window, the same supervised request waits3 minutes then
starts a new cycle, while its original request deadline permits. There is no
scheduled job/watcher/wake or new task/session. Cancellation interrupts backoff and
cooldown; no old tool is replayed. Existing request deadline still terminates an
unrecoverable outage; this is not a guarantee that tasks can never stop. Native
transport policy is unchanged. Test-only descriptor inputs can shorten the fixed
60s/180s windows for hermetic tests; production Lua sends only the retry count and
original timeout.

The bubble's shared `<wa-retry>` topic shows1/10…10/10, cycle number, failure
stage/code/reason and elapsed/countdown. Cooldown says “Reconnecting in 3 minutes”;
actual restoration folds the history, terminal failure/cancellation stays visible.
Display-only `role:'retry'` transcript rows preserve updates across reload/main/child
hosts; inference and compaction exclude them without deleting originals. A crash
leaves recovery unfinished, not a manufactured success or automatic effect replay.

Risk: the provider may have computed/billed the lost inference. Attempt diagnostics
mark usage unknown; recovered results record transport_failed_attempts so whole-call
cost is unknown even when the successful attempt's usage is measured. No returned
or previously dispatched tool is replayed. A repeated failure remains visible.
This prevents opaque-error loss in the observed path, not every possible network
outage or proof of which server/proxy closed a historical socket whose cause was
already discarded. Validate with `scripts/test-subscription-transport.cjs` in
an isolated evidence directory, plus existing bridge/observability tests.

Risk: this intentionally depends on Pi's installed adapter API and OpenAI's private usage
endpoint. Update Pi to a version whose catalog includes the GPT-6 family; an id the installed Pi
predates still resolves when the store publishes it for this route, and anything else fails
visibly rather than being substituted. Incompatible/missing dependencies fail visibly.
The graph audit does not resolve calls inside the embedded JavaScript string;
the bridge's offline contract test and real subscription exchanges cover that boundary.
