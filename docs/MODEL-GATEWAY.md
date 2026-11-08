# The model gateway as a component (`wa:model`)

Status 07/11: the seam's **logic is landed and tested** (`rust/wa-model-gateway`, 79 native tests), the
**component is built** (`rust/components/model-gateway`, `wasm32-wasip2`, `wa:kernel@0.2`), the **loop side
is landed behind a flag** (`lua/core/model_gateway.lua`, `WA_MODEL_GATEWAY=1`, native path unchanged), and
the **host capability that calls the component is not wired yet** — `host.model_gateway` is the one missing
piece, and without it the flag logs `component_capability_missing` and serves natively. What is here is
the contract (`wit/model/model.wit`), the rules, the adapters and the numbers; what is not is the
wasmtime edge, because that lands with the WASI 0.3 runner work rather than beside it.

Why this seam and not another (`docs/CORE-SPLIT.md`): the provider call is the hottest thing in a turn, and
it is the last thing that should move. It moves now for one reason the loop cannot serve: **the data
label**. "Which provider may see this message" is a decision that has to be enforced *before* bytes leave
the node, in one place, whatever path the turn took. Everything else here (fallback, breaker, budget,
accounting) is the routing that a gateway can own once it owns that decision.

## The contract

`wit/model/model.wit` — `package wa:model@0.1.0`, one world (`model-gateway`) importing
`wa:kernel/http|kv|log|credentials@0.2.0` and exporting `chat` and `embed`:

```wit
chat: async func(request: chat-request) -> result<stream<event>, error>;
explain: func(request: chat-request) -> result<explanation, error>;   // the dry run
configure: func(policy-json: string) -> result<u32, error>;            // live reload, answers the generation
routes: func(label: label) -> result<list<route-line>, error>;         // `wa models`
accounting: func() -> list<accounted>;
reset-accounting: func();
embed: async func(request: embed-request) -> result<embeddings, error>;
```

* A caller names a **task class** (`plan`, `code`, `cheap`, `vision`, `default`) **or** an explicit
  `provider/model` ref. The class is what picks a model; a caller that names a model is still subject to
  the label rule.
* `event` is `delta(text) | reasoning-delta(text) | tool-call(tool-call) | usage(usage) | finish(finish)`.
  Tool-call argument deltas are assembled **here**, not by the caller: one call crosses the seam.
* A **refusal** (`label-not-allowed`, `no-route`, `budget-exceeded`, `invalid`) is a typed answer, not a
  string: `chat` answers it before a stream exists, so the loop never opens one to learn it was refused.
  A **fault** (a provider that broke) is the other case, and it says whether anything was already shown to a
  reader (`StreamCut { emitted }`) — that is the difference between a retry and a duplicated answer.
* **JSON appears in exactly three places**, each named: `tool-def.schema-json` (the model's own parameter
  schema), `tool-call.arguments-json` (the model's own arguments) and `policy-json` (the operator's
  `models` section). Nothing the seam *decides* is JSON.

## Data labels — the reason the component exists

Every request carries `public | internal | client`. `client` is the strictest: a message from a client of
the operator (a WhatsApp/email correspondent, unless the chat is the operator's own), and a tool result
inherits the label of the source it read. A session's label is the strictest label seen in it
(`lua/core/model_gateway.lua` persists it per session; a session with no recorded source is `client`, so a
wiring mistake loses capability rather than leaking).

Each provider in policy has `allowed_labels`. A candidate whose provider does not allow the request's label
is **never a candidate**: the router drops it with a typed reason, the call is served from the next allowed
provider, or it is refused `label_not_allowed` with the reason naming what the provider does allow. The
default policy is what the job asked for and what `policies/default.json` will carry: DeepSeek/opencode-go
are `public|internal` only; Anthropic (and a local endpoint, if the operator declares it) may carry
`client`.

A provider that names **no** `allowed_labels` inherits today's provider: it allows `public` and
`internal` (the operator's own text and the operator's own material — what a turn carried before the
gateway existed, so the default changes no behaviour for either), and it never allows `client`. A
`client`-labelled request that can only be served by such a provider (DeepSeek, opencode-go) is refused
with the sentence that says what to do about it:

```
label_not_allowed: deepseek/deepseek-v4.1-flash is labelled client and deepseek allows public,internal
  - configure a provider allowed for client data
```

**Allowing a provider to carry client data is one line**, and it is always a decision an operator writes
down rather than a default:

```json
"providers": [
  { "id": "anthropic", "kind": "anthropic", "base_url": "https://api.anthropic.com",
    "credential": {"secret": "ANTHROPIC_API_KEY", "header": "x-api-key", "scheme": "raw"},
    "allowed_labels": ["public", "internal", "client"] }
],
"routes": {"plan": ["anthropic/claude-sonnet-4-5", "deepseek/deepseek-v4.1-flash"]}
```

The class that may see client data routes to that provider first; every other class keeps its own route.
Naming `client` on a provider that cannot be reached from the request's class changes nothing — a label
can only be *added* to a provider, never inherited by one.

The test that matters is an assertion on the bytes the mock provider received: a `client`-labelled request
produces **no request at all** to a provider that does not allow it
(`integration::a_client_request_never_reaches_a_provider_that_does_not_allow_it`).

## Providers, streaming, credentials

| adapter | endpoint | streaming frames the seam reads |
| --- | --- | --- |
| Anthropic Messages | `POST {base}/v1/messages` | `message_start` (usage incl. cache read/write), `content_block_*` (`text_delta`, `thinking_delta`, `input_json_delta`), `message_delta` (`stop_reason`, output tokens), `message_stop` |
| OpenAI-compatible (DeepSeek, opencode-go, local) | `POST {base}/chat/completions` | `choices[0].delta.content`, `delta.reasoning_content|reasoning|reasoning_text`, `delta.tool_calls[]`, `finish_reason`, `usage` |
| Google Gemini | `POST {base}/v1beta/models/{model}:streamGenerateContent?alt=sse` | `candidates[0].content.parts[]` (`text`, `functionCall`), `usageMetadata`, `finishReason` |

**API keys never enter the component.** A provider spec names a secret
(`credential: {secret, header, scheme}`); the adapter puts a *reference* on the request
(`wa-credential: <header>:<scheme>:<secret-name>`) and the kernel's `wa:kernel/http` adds the value from
`wa:kernel/credentials` (the vault backs that later). The guest cannot log what it does not have, and the
test asserts no key is in any body or header.

## Policy: `models` in policy.json (live reload)

```json
"models": {
  "version": 1, "generation": 7,
  "providers": [
    {"id": "deepseek", "kind": "openai", "base_url": "https://api.deepseek.com/v1",
     "credential": {"secret": "DEEPSEEK_API_KEY", "header": "authorization", "scheme": "bearer"},
     "allowed_labels": ["public", "internal"],
     "models": ["deepseek-v4.1-flash"],
     "timeout_ms": 45000, "breaker": {"failures": 5, "cooldown_ms": 30000},
     "rates": {"input_per_mtok": 300, "output_per_mtok": 1200, "cache_read_per_mtok": 30}}
  ],
  "routes": {"plan": ["anthropic/claude-sonnet-4-5", "deepseek/deepseek-v4.1-flash"]},
  "embeddings": {"default": ["deepseek/deepseek-embed"]},
  "budgets": {"node_tokens_per_day": 50000000, "session_tokens": 2000000},
  "defaults": {"timeout_ms": 60000, "max_attempts": 3, "backoff_ms": 400, "backoff_max_ms": 8000}
}
```

* A class with no route of its own falls back to `default`; a class with neither is `no_route`.
* `hosts` is derived from `base_url` (`api.deepseek.com:443`) and is what the manifest's `net` grant and
  the policy's `net.dial` rules are written against.
* Errors name the path (`models.routes.plan[0]: …`) — a policy file that silently defaults is a policy that
  cannot be audited.
* `configure` installs a new section and answers its `generation`; a call in flight keeps the policy it
  started with. A malformed reload is refused and the previous policy stays in force.

## Fallback, backoff, breaker, budgets

* **Retryable**: 429, 5xx, 401/403, 408, timeout and transport failure → the breaker records the failure,
  the jittered exponential backoff runs (the provider's `Retry-After` wins, up to `backoff_max_ms`), the
  next candidate is tried. **Not retryable**: any other 4xx (the request's own fault) and a stream that
  broke after items were delivered.
* **Breaker** per provider: opens after `failures` consecutive provider-side failures for `cooldown_ms`,
  then admits exactly one trial call; success closes it, failure re-opens it immediately. A 400 never opens
  it. A route emptied only by open breakers is a retryable failure, not `no_route` — the loop should wait,
  not change its model.
* **Budgets**: tokens/day per node and tokens per session, charged with prompt + output + reasoning.
  A drained budget refuses before a byte leaves when the caller supplied an estimate; the charge after a
  call is what the provider reported, never the estimate.
* **Accounting**: one record per call (session, provider, model, class, label, usage, cache read/write,
  cost in micro-units, cache hit, latency). No field can carry message text.

## Prompt cache

The gateway **never reorders, merges or rewrites** `messages`, `tools` or a cache breakpoint. The adapter's
body is the caller's order, the breakpoint stays on the message the caller put it on (Anthropic gets a
`cache_control` there; OpenAI-compatible endpoints have no request-side breakpoint and none is invented),
and nothing time- or session-derived goes into the body. `ChatRequest::prefix()` is the ordered prefix up
to the last breakpoint, and the tests assert that appending a turn does not move it, that two identical
requests send identical bytes, and that the body a gateway call sends is byte-identical to a direct
adapter call. `scripts/test-prompt-cache.lua` (the loop's own cache test) still passes with the flag off,
which is the check that matters for the cachelock freeze.

## `wa models` (explain a decision)

`explain(request)` is a dry run: the same planning function the call uses, no transport, one line per
candidate and the decision.

```
class plan label client
  ✗ deepseek/deepseek-v4.1-flash (openai, allows public,internal) — route#1: label_not_allowed: … is client and
    deepseek allows public,internal - configure a provider allowed for client data
  ✓ anthropic/claude-sonnet-4-5 (anthropic, allows public,internal,client) — route#2
would call anthropic/claude-sonnet-4-5
```

`routes(label)` prints every class at one label. Both are the component's exports, so the CLI reads the
node's live policy, breaker state included, rather than a second implementation.

## Cost (OPTIMIZATION CHECK, `bash scripts/bench-model-gateway.sh`)

Measured on the laptop (Windows, release, localhost transport, no network; body = 67 SSE frames, 3.4 KB;
n = 5000 same-process calls):

| measurement | p50 | p95 |
| --- | --- | --- |
| `body` — adapter serializes one provider body | 8 µs | 12 µs |
| `decide` — shape + label + breaker + budget + route | 2 µs | 3 µs |
| `parse` — build + parse the whole stream into items | 8 µs | 10 µs |
| `refused` — a whole call the provider rejects (no parsing) | 10 µs | 13 µs |
| `tiny` — a whole call with a 3-event stream | 14 µs | 24 µs |
| `gateway` — a whole call with the 67-event stream | **186 µs** (110–190 across runs) | 240 µs |

RSS is not printed on Windows (no `/proc/self/status`); the example prints `n/a` there rather than a zero.
The component is a 14 MB debug `.wasm` (release build is the shipping shape; the guest's memory limit is the
manifest's 128 MB).

**The named risk**: with a 67-event stream the whole call measured 110–190 µs p50 across runs while the
same parse isolated measured 7 µs, and a 3-event call measured 14 µs. The gap scales with the number of
events (~2 µs per event) and is **not yet explained**; the seam's own decisions are 2 µs. It is the first
thing to profile before this seam is enabled on a node — the suspects are the per-event allocation in
`absorb`/`Event` and the Windows allocator, not the routing. Reporting the range rather than one number is
deliberate: on this machine the same code produced both ends of it.

## Router modules

The gateway owns the call; it does not own the opinion of *which* model a class of work prefers. That
opinion is a **policy module** (`wit/model/router.wit`, package `wa:model-router@0.1.0`, logic in
`rust/wa-model-router`):

```wit
interface router {
    decide: func(request: request) -> decision;   // ordered candidates + skills, nothing else
    info: func() -> info;                         // name, version, classes, labels
}
record request  { class: string, label: string, explicit: option<model-ref>, session: string }
record decision { module: string, source: string, candidates: list<model-ref>,
                  skills: list<string>, fallback: option<string> }
```

* **The default module is today's routing.** `DefaultRouter` answers an explicit model, else
  `models.routes[class]`, else `models.routes.default`, else nothing - and a test compares it candidate by
  candidate, for every class and label, against `wa_model_gateway::plan_chat`, including the `source`
  string (`route:plan`, `route:default`, `none`, `explicit`). Enabling the seam changes nothing until a
  policy module is installed.
* **A policy module is a table** (what a component ships), parsed strictly so a typo is a named error
  (`module.rules[0].models[0]: "nomodel" is not a provider/model reference`):

```json
{"name": "fleet-ops", "version": 1,
 "description": "Fleet operations go to the strong model and load the fleetops skill.",
 "rules": [{"name": "fleet-ops", "classes": ["fleet-ops", "plan"],
            "labels": ["public", "internal", "client"],
            "models": ["anthropic/claude-sonnet-4-5", "deepseek/deepseek-v4.1-flash"],
            "skills": ["fleetops"]}]}
```

  `classes` may name a class the gateway's enum has no case for (`fleet-ops`): the loop passes the name it
  has, and a class the policy does not know arrives as `default`. `skills` is a **hint** for the caller
  (the fleetops skill in `skills/fleetops`), never a load performed by the gateway.
* **Installed, upgraded and switched like a service component.** `RouterRegistry` holds the installed
  modules, one is current, `install` adds or upgrades (a new generation; a downgrade is refused), and
  `switch_to` changes the current module. `decide` clones the current module first, so **a swap changes
  the next call and a call in flight keeps the module it started with** - by construction, not by timing.
  A module that has no rule for a request declines (`fallback`), and the gateway answers with the default
  module and says so in `source` (`route (fallback: fleet-ops: no rule for class cheap label internal)`),
  because a silent second default is a policy nobody can audit.
* **Two boundaries the module cannot cross.** A module may *narrow* the labels its rules apply to, never
  widen them: the gateway's own label gate runs on every candidate after the router, so a rule that names
  a public-only provider for a `client` turn changes nothing (and a test asserts exactly that). And a
  decision carries model refs and skill names only - messages, tools and the cache breakpoint never
  appear in the interface.

The component side is a thin guest over this crate's `RouterModule`: `rust/components/model-gateway` gains
the module in its world (a `wa:model-router` import), and `configure` installs a module declaration the
same way it installs the `models` section. Until that lands, the crate is tested natively
(`cargo test -p wa-model-router`, 8 tests) and the node's routing is unchanged.

## What integration needs (after the WASI 0.3 / wasmtime 50 runner lands)

1. **`host.model_gateway`** in `rust/wa-capabilities` (the `host.*` registration next to `host.selfloop`),
   calling the `wa:model/chat` export through the runner in `rust/wa-kernel-runtime`
   (`service_components_v2.rs`'s instantiate-and-call path), plus the driver that drains the guest's
   `stream<event>` into the JSON answer `lua/core/model_gateway.lua` expects (`as_result`).
2. **The credential header** `wa-credential: <header>:<scheme>:<secret>` in the kernel's `http` host impl:
   resolve through `wa:kernel/credentials`, strip the header, never log the value.
3. **Policy plumbing**: `policies/default.json` gains the `models` section above (narrowed to the node's
   providers), the loop calls `configure` on boot and on policy reload, and `wa models` maps to
   `routes`/`explain`.
4. **Sources call `note`**: `wa-whatsapp`/`wa-email` inbound handlers call
   `model_gateway.note(session, {kind="channel", own_chat=…})`, and the tool dispatcher calls it with
   `{kind="tool_result", inherited=…}`. Until then, sessions default to `client` (fail closed): a
   `client`-labelled request is refused on every provider that does not name itself for client data,
   which is every provider at its default (`label_not_allowed: … configure a provider allowed for client
   data`). That is the deliberate cost of failing closed, and it is why wiring the sources is the first
   item on the list above.

Since 08/11 the `gateway` *feature* is on by default (`docs/FEATURES.md`); what is still behind a flag is
the seam itself (`lua/core/model_gateway.lua` reads `WA_MODEL_GATEWAY` once at load), because
`host.model_gateway` is not wired yet. `wa features` reports exactly that: `enabled: true, active:
native, reason: component_missing` on a node without the component, `active_component` with it.
5. **A real streaming loop** in the library (`Transport::send` → `async`) so the component's events reach
   the caller during the call instead of after it (see the component's module docs).
6. `components.lock` gains the pinned `model-gateway` artifact when the first node ships it.
7. **Router modules**: the gateway component imports `wa:model-router/decide`, `configure` installs a
   module declaration beside the `models` section (generation included), and `lua/core/model_gateway.lua`
   passes the class **name** it has (`fleet-ops` included) so a policy can name a class the enum lacks.
   Until then `rust/wa-model-router` is the tested library and the native path routes exactly as today.
8. **`host.fleetview`** (docs/FLEET-OPS.md) in `rust/wa-capabilities`, calling `wa-fleetview`'s `assemble`
   after the peer read it needs; `lua/core/fleetview.lua` is the live collector until then, and both keep
   the same `FIELDS` contract.
