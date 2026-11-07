# The core split: what stays in the turn loop, what becomes a component

Status (07/11): the map below is the decision, and the first two extractions are **landed** — the
self-loop (behind `wa:selfloop`, `wit/selfloop/selfloop.wit`, `rust/components/selfloop`) and code mode
(behind `wa:codemode`, `wit/codemode/codemode.wit`, `rust/components/codemode`, importing
`wa:kernel/quickjs` for the sandbox the kernel hosts), both routed by their own `WA_*_COMPONENT=1`, both
with the native path unchanged and parity asserted (`scripts/test-selfloop-component.lua`,
`scripts/test-codemode-component.lua`). Hooks and mesh are specified here, not built.

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
| `hooks.lua`, `hook_events.lua` (hooks/mods) | **component third** (`wa:hooks`) | event→layers→verdict is a pure function of configuration; the plugin bodies stay capabilities | 1 call per hookable event; 0–2 per turn, more on bus events |
| `nodes.lua`, `federation.lua`, `routed_calls.lua`, `mesh`/fleet parts of `orchestrator.lua` | **component fourth** (`wa:mesh`) | roster, grants and routing decisions over the roster table; the transports stay capabilities | per peer call; 0 in a single-node turn |
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

## The next three interfaces

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

// wa:mesh@0.1.0 — the roster and the routing decision. The transports stay capabilities
// (`wa:kernel/net`, the relay), because a component must not own a socket.
package wa:mesh@0.1.0;
interface mesh {
    record peer { node-id: string, hierarchy: string, roles: list<string>, grants: list<string> }
    record route { peer: string, grants: list<string>, reason: string }
    roster: func() -> result<list<peer>, error>;
    route: func(capability: string, target: option<string>) -> result<route, error>;
}
world mesh-component { import wa:kernel/sql@0.1.0; export mesh; }
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
3. **hooks/mods** — pure, event-driven, and the node fires from many threads; a component makes the
   rule set swappable per event rather than per process.
4. **mesh/fleet** — the widest and the least urgent: a single-node turn never touches it, and its
   transports are capabilities that stay native.
5. **the model gateway** — last, and not a component in this sense: it *replaces* `provider.lua`, and
   it will be a service with its own process topology rather than a guest with a grant.

## Cost (measured)

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
5. **One router per seam, or one?** `memory.lua` and `selfloop.lua` each grew a ~40-line seam block
   (`seam`, `routed`, `note_fallback`). A third copy is the point to factor it into
   `lua/core/seam.lua` — with the same three-answer shape (`result`/`refused`/`ok:false`).
