# Progressive envelope and web research

## Model boundary

New operator sessions use eleven stable bootstrap declarations: remember, recall,
skill, tool_search, tool_call, read, read_many, write, edit, bash and session_worktree.
`read_many` is explicitly part of the main loop, not deferred. See
`docs/LAYERED-PROMPT.md` for the generic/stack/workflow/project/session sections.
`WASM_AGENT_BOOTSTRAP_MODE=classic` restores the former thirteen (including
capabilities and tool_result); invalid values refuse. The role-filtered execution catalogue remains
complete. `tool_search` loads matching exact definitions into the transcript;
`tool_call(name, arguments)` routes a loaded definition through the existing
native dispatcher. There is no JavaScript interpreter or new authority in this
facade. Scope, profile, workspace, effect reservation and target checks still run.
Unknown/plugin effects remain conservatively effectful. `tool_call(checked=true)`
validates the target's current supported JSON-schema subset before dispatch;
unsupported constraints (including composite enum values) refuse. Ordinary singles
retain their existing behavior. `calls` preflights one to eight already-known
independent pure local reads (read, grep, ls, recall, skill, capture_inspect),
then dispatches serially. It is neither concurrency nor a transaction and never
admits bash, mutations, MCP or plugin effects. Current permissions and definition
hashes are rechecked before each dispatch; cancellation/authority drift leaves
an explicit unexecuted suffix. Null array slots and duplicate raw members refuse.
Name/arguments, calls and cursor forms are exclusive. Large group replies page
captured originals using tool_call(cursor); they cannot cross read_many cursor
ownership, accounts or workspace/profile scope. Cursor retention has no TTL/quota.

Call shapes weaker models get wrong are repaired only where one reading exists, and
every repair is reported in the result's `normalized` field (`scripts/test-remote-call-shape.lua`).
`tool_call` parses `arguments` sent as a JSON-object string, unwraps a doubled
`{name, arguments}` wrapper, and moves parameters placed beside `name` into
`arguments`; the same key in both places with different values is refused. `remote`
is flat - `{node, capability, command|path|...}` - and still accepts the nested `args`
form; a `node`/`capability` missing at the top but present exactly once inside `args`
is hoisted, unless the target declares that key itself. Argument text that only lacks
trailing `}`/`]` is completed (`json_contract.close_truncated`) when the result
validates against the tool's schema (and, for `tool_call`, the target's);
`WASM_AGENT_ARGUMENT_REPAIR=0` disables that. Refusals name what arrived (type and
keys, never values), the online nodes where relevant, and a minimal correct call.

The first system message and declaration array do not grow when optional tools
are discovered. The transcript does grow by selected definitions and results.
Optional skills, including WhatsApp, are discovered with `skill(query="<task>")`;
metadata no longer populates new progressive prefixes. `skill(name="<match>")`
returns the unchanged complete body and directory. Query `*` enumerates all
visible metadata with explicit counts/offset/snapshot; changed catalogue or
account/session/role/profile/workspace refuses continuation. Hidden metadata stays
hidden; explicit hidden loading keeps its prior contract. Shared procedure policy
stays once in the system prompt, not duplicated into every loaded skill reply.
Mandatory role/project instructions and reasoning replay are not cut.
No memory facts, spell catalogue, connector catalogue or web originals are injected.
AGENTS.md is unchanged. Cached definitions are not free context; provider cache
hits and billing savings are unmeasured by the shadow fixture.

Loaded names are session/user/role scoped and hash-fenced in SQLite. Discovery
never authorizes a tool. Role/profile ceilings and current MCP approval are checked
again at invocation; changed definitions require rediscovery. Raw nested MCP JSON
arguments preserve null/empty-object/empty-array shapes. Duplicate routed JSON
members refuse. Full original history/results stay retrievable. Compaction can
remove a definition from active context, so search it again when its contract is
no longer visible; a loaded hash is not proof of model awareness.

Existing conversations with recorded assistant activity keep the full surface;
user-only unanswered sessions may adopt progressive mode. Children keep their exact approved
profile declarations. `WASM_AGENT_ENVELOPE_MODE=full` is the explicit rollback.
`progressive` can force the new facade in a controlled session. Invalid settings
fail, not silently choose a mode. Default new-session promotion is the operator's
requested treatment; the risk is an added discovery step and unmeasured autonomous
model behavior beyond this small fixture. The escape hatch and evidence remain.

## Binding-aware execution discovery

`tool_search`/`capabilities` expose caller-scoped workspace execution metadata
before invocation, separately from permission and exact schemas. Blocked/unknown
definitions are not loaded. For bound `client`, including status, provide an
existing artifact link or report the limitation; do not invoke/retry it or use
another executor/session to bypass the binding. Conditional tools still require
native argument/preflight checks. See [BINDING-DISCOVERY.md](BINDING-DISCOVERY.md).
The stable bootstrap and role/profile/effect boundaries remain unchanged.

## Skill discovery and remaining Pi gap

The retained Pi1.2 SDK replay selects read/bash/edit/write/codemode and supplies
no skill catalogue; it is not the complete autonomous Pi agent. The older patched
capture lists WhatsApp only in skill metadata, not as a bootstrap tool. Its
catalogue is9,256bytes and its13 tool schemas9,020bytes versus Pi's five4,479bytes.
These are recorded treatment differences, not proof our routing facade has the
same execution semantics or cost as Pi's JavaScript codemode.

`test-skill-discovery.cjs <candidate-wa> <fresh-evidence> <baseline-wa>` and
`--post` exercise source/embedded discovery, complete bodies, caller/metadata
snapshots, hidden/guest/profile boundaries, fixed-prefix growth and an exact
old-API negative control. Native embedded before/after captures hold the source
cwd/current catalogue constant. Run existing envelope and complete-body proofs too.
The scope is serialized bytes and deterministic contracts, not provider tokens,
billing, cache hit rates or autonomous task quality. First unknown procedure use
can add a discovery round; lexical search can miss synonyms. Known names load
directly and complete enumeration remains available. Full mode is the rollback.

## Task-local guidance, capture inspection and outcome scope

Progressive prefixes no longer duplicate the bootstrap tool index or the concise
style instruction. Optional UI instrumentation guidance arrives with client/shell
discovery; capture/read-result guidance arrives with those definitions. Mandatory
project, role, memory, workspace, skill-use and unknown-effect policy remains.
Full/legacy prompts and exact child profile declarations retain their contracts.

Discover `capture_inspect` before inspecting retained model-request JSON. Default
summary selects one request, with bounded tool names and explicit omission counts;
limit (max8), offset and source-hash snapshot cover subsequent metadata. Exact
request/tool/message views preserve raw null/object/array distinctions. The complete
original is unchanged and hash-addressed. These are structural sizes/counts, not a
content summary or task-quality verdict. Unsupported layouts, ambiguous JSON or
source drift refuse. Arbitrarily large selected views can still require original
byte retrieval; the global50KiB output budget is unchanged, not silently clipped.

Run `test-envelope-iteration.cjs <built-wa> <fresh-evidence> <exact-capture>` and
`test-envelope-outcomes.cjs <built-wa> <fresh-evidence>`, then each `--post`.
The former covers source/embedded structural/typed/scope/cursor contracts. The
latter runs five predeclared native tool paths under classic13 and lean10,
with failing-before/passing-after code-repair and memory/capture oracles. It records
initial, peak and summed input serialization, total tool-result bytes, discovery
calls, wrapper invocations and planned model-round snapshots. It is not an
inference-driven benchmark or an actual full agent-loop comparison with Pi.
No provider calls, tokens, cache/billing or autonomous quality are measured.

The nine-tool pilot deferred remember, added discovery and worsened total task
context; remember therefore stays immediate. Grouped capture calls save a wrapper
invocation, not a model round: existing independent singles already share a model
response and both paths still perform two reads. The measured group has75 fewer
input bytes but76 more newly emitted result bytes: one byte worse on their sum,
not a demonstrated total-cost improvement. See
`docs/measurements/envelope-iteration.json` for qualified results/limitations.
`WASM_AGENT_ENVELOPE_MODE=full` and bootstrap classic remain rollback knobs.
There is no added JavaScript engine and no claim of codemode parity with Pi.

## MCP reads, writes and results

Approved generic reads and the fixed web facade reuse a supervised read-session
process. Connection keys bind caller/session/role, definition, credential hashes,
read-only names and approved schema hash. No shared cross-account client exists.
An idle session closes after30 seconds; an operation deadline still bounds it.
There are no jobs, model polling, subscriptions, detached workers or inference.
Native operation ownership/process-tree containment remains the supervisor.

Initialize/list happen once per live read connection. A tool-list notification
causes on-demand rediscovery; changed approval hashes refuse before the next
app call. Silent server changes without notifications cannot be detected from a
cached catalogue: explicit re-probe is the refresh boundary. This limitation is
not relabeled per-call verification. Writes, probes and WhatsApp retain their
request-scoped settlement/effect contracts. No unknown call is retried. Read
uncertainty is reserved durably before HTTP submission and released only after
hash-bound known result verification. Missing/malformed acknowledgements, native
interruption and process reconstruction retain the exact request and refuse replay;
a competing uncertainty claim cannot submit. Fixed built-in facades pin the initial
connected catalogue too. Cancelling a process is not semantic settlement.

Generic replies expose the actual result/error and a hash-bound evidence pointer,
not the entire server catalogue again. Exact request/result files and operation
records remain private originals. A persistent-call acknowledgement proves that
call's retained response, not that its still-live session process has settled.

The one-shot stdio cleanup also fixes two costs: waiting for an already-fired
close event and leaving losing race timers alive. Do not attribute that eliminated
one-second delay entirely to process startup or persistent connections.

## Web interface

Discover `web_search` and `web_read` through tool_search, then use tool_call.
They are fixed, read-only MCP-backed native facades. No generic connector enabling
or account creation is needed. Search queries leave the machine: the live default
is anonymous DuckDuckGo HTML. Detected challenges return an evidence-backed human
handoff; documented async acceptance returns a pending handle for one later monitor
read. No CAPTCHA bypass, browser/cookie reuse, automatic polling/query replay or
paid API is introduced. See `docs/WEB-HTTP-OUTCOMES.md`. Bing RSS was tested and rejected as the live
default after irrelevant results; its failed-quality evidence is retained.

The reader supports public HTTPS static HTML/text/JSON/XML, not JavaScript rendering,
PDF extraction, browser actions or Firecrawl parity. Public DNS addresses are
checked and pinned per request; redirects are validated separately, credentials
and private targets refuse, and response sizes/deadlines are bounded. No cookies
or authenticated browser profile are used. Source content is untrusted data.

Successful originals, extracted text and metadata are content-addressed locally.
Responses include citations, an immutable ref and explicit UTF-8 byte paging.
Repeated URL reads reuse a recent public-source cache; ref reads never fetch.
Changed cached bytes refuse. Full raw HTML remains available even when scripts,
styles and templates are excluded from the static text view. Cache is explicit
retention, not a disk quota or a promise the page is still current; refresh requests
fetch anew. Selected search results count omitted cached candidates explicitly.

## Focused proof and shadow scope

`scripts/test-envelope.lua`, `test-mcp.lua`, `test-web.mjs` and
`test-mcp-session.mjs` and `test-mcp-recovery.cjs` cover native discovery, source/embedded freshness, permission
and schema fences, raw shapes, connection reuse/notification/unknown no-replay,
public target refusal, cache integrity and complete Unicode paging. Existing
MCP/WhatsApp tests remain. No full release gate is implied.

The fixture `benchmarks/web-envelope/simple.json` is one question, one search, two
short authored sources, two citations, and one cached follow-up. It is intentionally
not a broad research task. `scripts/bench-web-envelope.cjs` runs25 serial,
counterbalanced repetitions per arm: frozen current wasm, patched wasm, and
privately pinned latest Pi. Every arm receives the same question/corpus/backend;
independent acceptance rejects missing facts/citations and extra app calls.

Wasm uses its real native agent loop with recorded model responses. Pi uses its
published MCP/codemode SDK and prompt/declaration builders with recorded scripts,
not its autonomous CLI agent loop. Therefore bytes/protocol/replay timing are
mechanical shadow evidence, not an apples-to-apples autonomous agent ranking.
Different bootstrap capabilities, mandatory role instructions and skills are
visible treatment differences, not silently normalized away. Setup is separate
and also included in end-to-end wall time. Exact provider tokens, cache hits,
subscription quota and dollars remain unknown; bytes are not measured tokens.

Run `test-progressive-envelope.cjs <built-wa> <fresh-evidence>` and its `--post`
check; `progressive-envelope-proof` records this verified sequence, while required
worktrees use the direct CLI without relaxing their binding. Native reconstruction
uses `test-mcp-recovery.cjs`; standalone embedded web uses
`test-web-shadow-embedded.cjs`. For the offline report, generate with
`render-envelope-report.mjs <qualified-wave> <fresh-output.html> <status.json>`,
then `test-envelope-report.cjs <report-dir-with-index.html> <fresh-proof>` and
`--post`. Inspect the screenshot; its content-mutation control must fail.

Run with absolute frozen baseline/Pi/binary/evidence paths; the evidence directory
must be fresh. `--post` verifies retained source/runtime/package/trace hashes without
replaying the experiment. The final HTML shows initial actual snapshots, expansion,
before/after distributions, applied improvements, failures and limitations.
Installation is separately observed through the exact-source Sentinel receipt.
