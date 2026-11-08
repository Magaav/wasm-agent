# The core split: what stays in the turn loop, what becomes a component

Status (07/11, updated by the hooks lane and the mesh lane): the map below is the decision, and five
extractions are **landed** — the self-loop (behind `wa:selfloop`, `wit/selfloop/selfloop.wit`,
`rust/components/selfloop`), code mode (behind `wa:codemode`, `wit/codemode/codemode.wit`,
`rust/components/codemode`, importing `wa:kernel/quickjs` for the sandbox the kernel hosts), memory
(`wa:memory`), **hooks/mods** (`wa:hooks`, `wit/hooks/hooks.wit`, `rust/components/hooks`) and the
**mesh/fleet decisions** (`wa:mesh`, `wit/mesh/mesh.wit`, `rust/components/mesh` over
`rust/wa-mesh-core`), each routed by its own `WA_*_COMPONENT=1`, each with the native path unchanged
and parity asserted (`scripts/test-selfloop-component.lua`, `scripts/test-codemode-component.lua`,
`scripts/test-memory-component.lua`, `scripts/test-hooks-component.lua`,
`scripts/test-mesh-component.sh`). The mesh's split is also a *Rust* crate split: `wa-mesh-core` is the
rules, compiled once for the node (ring) and once for the guest (dalek).

## The rule

`lua/core` is ~34k lines in one interpreter. Splitting it is not a goal in itself: a seam costs a
call, a copy and a place for the two halves to disagree. So a part becomes a component only when all
three answers are the same:

1. **Does it need the living turn?** A part that must see the session, the assembled prompt, the
   provider's stream or the model's tool call as it happens stays in the loop. Prompt assembly,
   session state, the provider call and tool dispatch are one object with one lifetime; a component
   boundary through them would be a boundary through the middle of every turn.
2. **Is its state durable and its logic replaceable?** A part whose state is rows in the kernel's
   database and whose rules are a state machine, a policy or a ranking is a candidate: the rows stay
   the kernel's, the rules can be swapped, and a swap loses nothing because a restart re-reads rows.
3. **How often does it run, and off which thread?** Something that runs once per turn is a candidate
   only if it is cold *inside* the turn (a rare branch). Something that runs on the node's placement
   tick, on a webhook, or in a background thread is a candidate even at high frequency, because it is
   not on the turn's critical path at all.

Two consequences worth stating: the **model gateway** (provider discovery, route selection, retries,
streaming) is the last thing to move, not the first — it is the hottest and it is what a future
gateway replaces; and **nothing moves that the model sees mid-turn** (tool argument validation, tool
output shaping, the transcript), because a failed seam there costs a turn rather than a retry.

Status 07/11: the gateway is now **specified, built and off by default** rather than unstarted —
`wit/model/model.wit` (`wa:model`), `rust/wa-model-gateway` (the rules, 79 native tests),
`rust/components/model-gateway` (the `wasm32-wasip2` guest) and `lua/core/model_gateway.lua` behind
`WA_MODEL_GATEWAY=1`, with the native provider path unchanged. What is *not* landed is the host
capability that calls the component (`host.model_gateway`), so the flag currently logs
`component_capability_missing` and serves natively. The reason the seam exists at all is the **data
label**: "which provider may see this message" has to be enforced once, before bytes leave the node,
whatever path the turn took — see `docs/MODEL-GATEWAY.md` for the contract, the policy section, the
label rules and the measured cost.

## The map

Measured call frequency: `scripts/bench-core-calls.lua` wraps every `host.*` function and runs one
scripted turn (prompt assembly + local-fallback provider + one tool round). One turn = **295 host
calls**: `getenv` 92 (31%), `read_file` 47 (16%), `sha256` 30 (10%), `sql_exec` 30 (10%), `now` 27
(9%), `paths` 20 (7%), `sql_query` 17 (6%), `node_identity` 10 (3%), `monotonic_ms` 7 (2%), `uuid` 6
(2%), the rest 1–2 each. The self-loop contributes **zero** calls to a turn: its cost is per *tick*.

| `lua/core` module(s) | verdict | why | per turn / per tick |
| --- | --- | --- | --- |
| `agent.lua`, `provider.lua`, `prompt_sections.lua`, `prompt_cache.lua`, `tools.lua`, `tool_output.lua`, `envelope.lua`, `json_contract.lua`, `session_view.lua` | **stays** (the hot loop) | session state, prompt assembly, the provider call, tool dispatch: one object, one lifetime; the gateway replaces the provider later | 295 host calls, ~everything above |
| `selfloop.lua` (wakes, notes, probes) | **component, landed** (`wa:selfloop`) | a state machine over three tables; the node's tick and a restart both re-read rows; the probe *runner* and the agent turn stay in the loop | 2 host calls per tick native, 1 per seam op; ~1 op per wake |
| `codemode.lua`, `codemode_policy.lua`, `codemode_view.lua` | **component, landed** (`wa:codemode`) | the guest's protocol — the fence, its tool table, `searchTools`/`describeTool`, the admit/deliver order and the script's report — as a state machine over one script; the QuickJS *sandbox* stays in the kernel as a capability (`wa:kernel/quickjs`), and admission, dispatch, the definition recheck, evidence, presentation and the session store stay in the loop | 1 call per step (2 for a trivial script, 13 for ten parallel calls) on the rounds that use code mode; 0 on the rest |
| `hooks.lua`, `hook_events.lua` (hooks/mods) | **component, landed** (`wa:hooks`) | event→layers→verdict is a pure function of configuration; running a hook stays the node's (a process, or a Lua function); one call per hook answer, none on an inert node once the plan is cached | 1 call per hookable event; 0–2 per turn, more on bus events |
| `nodes.lua`, `federation.lua`, `routed_calls.lua`, `mesh`/fleet parts of `orchestrator.lua`, and (in Rust) `roster`/`hierarchy`/`policy`/`attest`/`audit`/`cache` decisions | **component, landed** (`wa:mesh`, `rust/wa-mesh-core`) | roster, grants, attestation bytes, audit line and dial order are a rule over documents and ids; the transports, the files and the node's key stay native | per peer call (0.2 ms through the seam); 0 in a single-node turn |
| `provider.lua`'s call site (`M.complete_with`) → `lua/core/model_gateway.lua`, `wa:model` | **component, built, off by default** (`rust/components/model-gateway`) | the *decision* (class → model, data label vs `allowed_labels`, fallback, breaker, budget) is a pure function of policy + session label; the prompt, the transcript and tool dispatch stay in the loop. The seam is only entered under `WA_MODEL_GATEWAY=1` | 1 call per provider call, and only when enabled; measured 2 µs of decisions, 7 µs of protocol (`docs/MODEL-GATEWAY.md`, "Cost") |
| `memory.lua` (recall, search, sessions, retention) | **component, landed** (`wa:memory`, see `docs/MEMORY.md`) | ranking and scope rules; `memory.db` stays the kernel's | 1–3 calls per turn |
| `chat.lua`, `cli_view.lua`, `cli_panel.lua`, `completions.lua`, `markdown.lua` | **stays** (the console) | it *is* the client: it draws, it reads input, it reloads with the window | — |
| `server.lua`, `subagents.lua`, `orchestrator.lua` (placement), `steering.lua`, `completions.lua` | **stays** (the node) | admission, scheduling, run ownership: the things a component must not own | — |
| `update.lua`, `release.lua`, `backup.lua`, `spells.lua`, `workspaces.lua`, `changeset.lua`, `integrate.lua`, `merge.lua`, `patch_audit.lua`, `graph.lua`, `skills.lua`, `file_tools.lua`, `read_batch.lua`, `history_search.lua`, `mcp.lua`, `mcp_session.lua`, `vault.lua`, `keys.lua`, `users.lua`, `access.lua`, `state.lua`, `resources.lua`, `wave_deploy.lua`, `nodes_cli.lua`, `stt.lua`, `voice.lua`, `audio`/`web`/`telemetry` | **stays** (for now) | each is either thin over a capability that already exists (`wa-graph`, the release scripts) or is the operator's surface; moving them buys nothing a swap can use | — |

The four extractions share a shape; once the second lands, the third and fourth are the same work.

## What a seam must look like

The memory seam (`docs/MEMORY.md`) and the self-loop seam set the rules; a new one that breaks them
is the seam to reject in review:

- **Typed records, versioned package** (`package wa:<name>@0.1.0`), never a JSON document across the
  boundary. Rendering (a trace, a model-facing line) may carry text, and the field says so
  (`probe-result.detail`, `event-rendering`).
- **Storage is the kernel's.** The component imports `wa:kernel/sql` scoped by its manifest to named
  tables, and runs no DDL: the schema is created by the core's `setup()` (a component with a grant has
  no `CREATE TABLE`, and a node whose schema is missing gets a visible `store-failed`).
- **A refusal is an answer; a failure is not.** The component's named refusals (the ones the model
  already knows: `wake_reason_required`, `memory_scope_full`, …) answer `ok:true` with the refusal,
  and the router returns them unchanged. Only "the component could not answer" falls back, with one
  log line per (operation, reason).
- **The host owns identity, time and the scheduler.** A component never names itself (no journal
  origin, no boot id, no uuid semantics), never runs the run scheduler, and never calls the model.
- **Parity is asserted, not assumed.** `scripts/test-<name>-component.lua` sends the same calls
  through both paths and compares field for field, ids normalised; `scripts/bench-<name>.sh` reports
  the cost difference. A skip is reported as a skip.

## The interfaces: what is left

Sketches only — each is a design note, not a contract until it lands.

```wit
// wa:codemode@0.1.0 — the code-mode policy: may this tool be called from inside the sandbox, with
// which limits, and what does the model see about it. The QuickJS sandbox itself stays a capability.
package wa:codemode@0.1.0;
interface types {
    record tool-facts { name: string, effect: string, read-only: bool, schema-json: string } // the model's own schema, opaque
    variant refusal { tool-not-in-codemode(string), effect-refused(string), limit-exceeded(string) }
}
interface codemode {
    use types.{refusal, tool-facts};
    // `effect` is the resolved class; `limits` are the sandbox's, not the caller's to invent
    admit: func(tool: string, effect: string, role: string) -> result<admission, refusal>;
    catalogue: func(role: string) -> list<tool-facts>;   // what the sandbox may call at all
    render: func(tool: string, outcome: string) -> result<string, refusal>;  // the model-facing line
}
world codemode-component { import wa:kernel/sql@0.1.0; export codemode; }

// wa:hooks@0.1.0 — event → layers → verdict. Deterministic; the plugin bodies stay capabilities.
package wa:hooks@0.1.0;
interface hooks {
    record event { name: string, session-id: string, user-id: string, role: string, cwd: option<string> }
    record verdict { blocked: bool, blocked-by: string, reason: string, reschedule-seconds: option<u64>,
                     system-messages: list<string> }
    fire: func(event: event) -> result<verdict, error>;
    bus: func(topic: string, identity: string) -> result<u32, error>;  // how many hooks ran
}
world hooks-component { import wa:kernel/sql@0.1.0; export hooks; }

// wa:mesh@0.1.0 — landed, and not the sketch that was here. The transports stay native (the listener,
// the relay, the peer cache file, the node's key), so the world imports *nothing*: the mesh stores no
// rows (no `wa:kernel/sql`), reads no clock (`now` is an argument) and holds no key. What moved is the
// decision, in the shape the node asks it in:
package wa:mesh@0.1.0;
interface mesh {
    verify-roster: func(document: string, fleet-key: string, now: u64) -> result<level-facts, roster-refusal>;
    decide: func(grants: list<grant>, facts: call-facts) -> verdict;
    verb: func(capability: string) -> string;
    render-audit: func(event: audit-event) -> string;
    attest-message: func(node-id: string, caller: string, verb: string, capability: string,
                         caller-signature: string, ts: u64) -> string;
    verify-ticket: func(ticket: ticket, node-id: string, node-public-key: string,
                        caller-signature: string, now: u64) -> result<ticket-facts, ticket-refusal>;
    addresses: func(target: node, learned: list<string>) -> list<string>;
}
world mesh-component { export mesh; }
```

## Order, and why this order

1. **self-loop** — the smallest state machine with real rules (scheduling, claims, refusals, notes),
   no model call inside its own half, and a natural split between "the state machine" (a component)
   and "run the probe / dispatch the turn" (the node). Landed: it proves the shape.
2. **code mode** — **landed** (`wa:codemode`). The boundary turned out to be the guest *protocol*, not
   the policy table: a component cannot host wasmtime, so the sandbox is imported (`wa:kernel/quickjs`)
   and what moved is the fence, the guest's tool table and discovery, the admit/deliver order and the
   report. Its cost, and the honest limits of measuring it without the provisioned guest, are in
   `docs/CODEMODE.md` "Code mode as a component". It also answers one open question by measurement:
   code mode is *not* the self-loop's shape — one instance per script is right, and a script that pays
   instantiation for `return 1` is 3.6 ms against the native 1.5 ms.
3. **hooks/mods** — **landed** (`wa:hooks`). The boundary turned out to be *the rules*, not the hooks:
   both config shapes, the matchers, the ordering, the per-hook timeouts, the protocol's
   interpretation, the bounds and the mods surface moved, while running a hook stayed the node's (a
   command is a process with the node's grants; a Lua plugin is a function in the interpreter) and the
   config files stayed the node's to read (a guest has no path to `~/.wasm-agent` and no grant to it).
   So the seam is two calls, not one: `configure`/`entries` say what runs and in which order, and one
   `decide` per hook answer says what it means - because only a verdict can say whether the next hook
   still runs, and the native loop breaks on a refusal. The cost of that choice is in "Cost" below;
   the shape is in `docs/HOOK-EVENTS.md`, "The engine as a component".
4. **mesh/fleet** — **landed** (`wa:mesh`, `rust/wa-mesh-core`). The widest and the least urgent (a
   single-node turn never touches it), and the one whose cost profile is the opposite of the self-loop's:
   the native path is *microseconds*, so the seam is a ~500x multiplier on the decision (0.2 ms and ~3 MB)
   rather than a saving. It is also the extraction that proved the rule "no key, no socket": the guest
   composes an attestation and checks one, and the node signs. Numbers, and the per-operation route
   (`WA_MESH_COMPONENT_OPS`), are in `docs/MESH.md` §10.
5. **the model gateway** — last, and not a component in this sense: it *replaces* `provider.lua`, and
   it will be a service with its own process topology rather than a guest with a grant.

## Cost (measured)

`bash scripts/bench-hooks.sh` on this machine (Windows, release build, median of 21 in-process fires;
one process per path; the hook command is a `sh` that answers `{}`):

| path | scenario | p50 ms | p95 ms | `host.hooks` calls per fire | peak RSS |
| --- | --- | --- | --- | --- | --- |
| native | fire, 0 hooks | 0.00 | 0.01 | 0 | 16.0 MB |
| component | fire, 0 hooks | 0.01 | 0.01 | 0 | 26.1 MB |
| native | fire, 1 hook | 63.8 | 64.6 | 0 | 16.0 MB |
| component | fire, 1 hook | 65.8 | 72.1 | 1 | 26.1 MB |
| native | fire, 10 hooks | 701.4 | 727.3 | 0 | 16.0 MB |
| component | fire, 10 hooks | 733.8 | 879.6 | 10 | 26.1 MB |
| component | decide one row, 1 hook configured | 0.47 | 0.51 | 1 | 26.1 MB |
| component | decide one row, 10 hooks configured | 1.46 | 2.21 | 1 | 26.1 MB |

Read it as: **the seam's own cost is ~0.5 to ~2 ms per hook answer** (the row is handed in; the
verdict comes back), and the round trip grows with the verdict's `outcomes` because the accumulated
verdict is what the next step carries. On this host a *hook* costs 60–70 ms (a process spawn), so a
turn with one hook pays ~3% more and a turn with ten pays ~5% more; the absolute numbers are this
machine's process spawn, not the seam's. An **inert node pays nothing** after its first
(event, tool) plan, because the matched entry list is cached per config generation exactly as the
native view is. RSS is +10 MB for the engine and one module instance, the same order as the self-loop
seam.

`bash scripts/bench-selfloop.sh` on this machine (Windows, release build, median of 21 in-process
runs; one process per path; `wa` = this checkout's build):

| path | scenario | ms | host calls | SQL statements | peak RSS |
| --- | --- | --- | --- | --- | --- |
| native | read (list+summary) | 0.46 | 4 | 4 | 13,768 KB |
| component | read (list+summary) | 3.63 | 2 | 4 | 26,148 KB |
| native | notes (write+read) | 0.57 | 5 | 5 | 13,768 KB |
| component | notes (write+read) | 3.39 | 2 | 5 | 26,148 KB |
| native | schedule a wake | 8.53 | 4 | 4 | 13,768 KB |
| component | schedule a wake | 2.24 | 1 | 4 | 26,148 KB |
| native | tick (probe unchanged) | 0.04 | 2 | 2 | 13,768 KB |
| component | tick (probe unchanged) | 1.69 | 1 | 2 | 26,148 KB |
| native | tick (dispatch one wake) | 0.10 | 2 | 2 | 13,768 KB |
| component | tick (dispatch one wake) | 1.59 | 1 | 2 | 26,148 KB |
| native | turn (content+finish) | 0.06 | 3 | 3 | 13,768 KB |
| component | turn (content+finish) | 4.92 | 3 | 3 | 26,148 KB |

Read it as: **the component moves work out of Lua and into one call** (the same SQL statements, in one
`host.selfloop` crossing instead of two to five `sql_*` ones), and **it costs ~1–5 ms and ~12 MB of
process RSS per call** because every call instantiates the guest (`memory_host` does the same). The
statement counts matching exactly is the parity evidence at the cost level: the component does the
same work, not less.

Honest caveats. (1) The `schedule` row is the one place the native path is *slower* (8.53 ms vs 2.24):
`host.uuid()` through the Lua ABI plus two statements cost more than the guest's whole call — a
measurement of this tree's capability path, not of "Lua is slow". (2) RSS is the whole process's peak:
an engine and a module instance for one guest, not a node's steady state. (3) These are per-call
numbers; the argument for the self-loop is not the 1.6 ms a tick costs but that its 1,100 lines of
rules are now swappable and testable apart from the interpreter. (4) Nothing here measures a *model*
turn: the gateway rewrite owns that, and these numbers do not predict it.

### The mesh seam (measured)

`bash scripts/bench-mesh.sh`, this machine (Windows, release, one process per path, p50/p95 over 2,000
samples). The full table is `docs/MESH.md` §10's; the shape of it:

| scenario | native | component |
| --- | --- | --- |
| `decide` (hierarchy, allow or deny) | 0.2–0.3 µs | 151–174 µs p50 / ~280–330 µs p95 |
| `verify_roster` (4 nodes) | 83 µs | 410 µs |
| `render_audit` | 1.1 µs | 153 µs |
| `addresses` | 0.4 µs | 155 µs |
| first call (compile + instance) | — | 1.7 ms |
| peak RSS | 5,196 KB | 8,184 KB |

So: **+0.2 ms and +3 MB per routed decision**, and the seam is worth it for the operations whose *rule* an
operator may want to swap (`decide`, the signature checks), not for the ones whose output is formatting
(`render_audit`, `addresses` — they pay the same price and buy nothing swappable).
`WA_MESH_COMPONENT_OPS` is that choice, per operation, without a rebuild.

## Open questions

1. **Instantiate per call, or pool?** The self-loop is called once per tick, so per-call instantiation
   is affordable and keeps the seam stateless. Code mode answered this by measurement
   (`docs/CODEMODE.md`, "Cost"): a script is **one instance held for the script**, not one per step and
   not a pooled lease — a step is the same instance continuing its own loop state, and a script that
   pays instantiation for `return 1` costs 3.6 ms against the native 1.5 ms. The cold start (238 ms,
   Cranelift) is once per artifact and engine, amortised by the compiled-module cache beside the
   component, and the next process opens a script in 4.6 ms.
2. **`async func` on WASI 0.3.** All of these seams are `wa:kernel@0.1` (synchronous). The records do
   not change; the functions become `async`, so a slow statement parks the guest instead of the caller
   (see `docs/KERNEL.md`, "Memory as a component", for the same open item).
3. **The probe runner.** A probe calls read-only tools *from inside the sandbox*, and the sandbox is a
   capability. Today the node runs it; a future `wa:tools` component would have to be the thing that
   answers it, which makes the self-loop seam one call deeper (a nested call), and nobody has measured
   whether that nesting is affordable per tick.
4. **Where the schema lives.** `setup()` (DDL) is still in the core because a grant has no DDL. When
   the last `setup()` moves to a migration runner owned by the kernel, the components can assume it —
   until then, a node that opens an old store gets one `store-failed` per operation, with a log line.
5. **One decision call per hook answer.** The hooks seam pays one crossing per **hook**, not per event,
because the node runs the hook and only the verdict says whether the next one still runs (the native
loop breaks on a refusal, and running a hook the native path would have skipped is a side effect a
seam must not invent). The alternative that would make it one crossing per event is the nested
callback the self-loop's probe question describes: the guest asks the *host* to run hook N and hands
the answer straight back. It needs a `wa:hooks/host` import and a synchronous host callback a
WASI 0.3 `async func` seam makes cheap; nobody has measured it, and the numbers above say what it
would buy (~2 ms per hook on a 60 ms process spawn).

6. **One router per seam, or one?** `memory.lua` and `selfloop.lua` each grew a ~40-line seam block
   (`seam`, `routed`, `note_fallback`). A third copy is the point to factor it into
   `lua/core/seam.lua` — with the same three-answer shape (`result`/`refused`/`ok:false`).
