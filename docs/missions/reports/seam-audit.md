# Seam audit: every internal seam, measured

Branch `change/race-seam-audit-W`. Phase 1 of the brief: inventory + measurement, no production code
changed. Every number below was measured in this worktree, on this node (avell, 16 cores, linux
x86_64), in a scratch `WASM_AGENT_HOME` and a scratch ledger, with the tree's own `wa` binary.
Nothing here touched a live node, the fleet, a real provider or the operator's ledger.

The law this audit serves (AGENT-SEAT, principle 0): the simplest change that works wins, and it is
measured before it is built. The architecture rule (18/11): a boundary between parts of wa is defined
in `wit/`, work that takes time returns a future, output that keeps coming is a stream, JSON stays only
where it is the outside world's format.

## What was run

| command | what it measures |
| --- | --- |
| `bash scripts/bench-seams.sh --iterations 200` | every capability seam: p50/p99 per call (CPU clock), bytes that cross, Lua's encode+decode of the same payload, and serde's parse+encode of the same bytes (`rust/wa-host-support/examples/json-cost.rs`) |
| `WA_SCRIPT=scripts/bench-core-calls.lua wa --db scratch.db` | the capabilities one turn calls and the bytes each returns (the per-turn row) |
| `bash scripts/bench-codemode.sh` | CodeAct run blocks, native vs component: median/p95 per script, crossings, RSS |
| `bash scripts/bench-mesh.sh` | the mesh decision seam, native vs component, per call |
| `bash scripts/bench-fabric.sh` | the fabric's placement decision and one offer round trip on loopback |
| `bash scripts/bench-operation-phases.sh` | the operation table's executor phases |

The bench itself is new in this branch (`scripts/bench-seams.lua`, `scripts/bench-seams.sh`,
`rust/wa-host-support/examples/json-cost.rs`, commit `8ae79507`; the turn-loop and vault rows in
`663e3f8b`). Building it forced one stale premise out of `scripts/bench-core-calls.lua`, fixed in
`8ae79507` - see "Premises the brief or the tree had wrong" below.

Machine and clocks, stated because a number without its clock is a guess: p50/p99 in
`scripts/bench-seams.lua` are of `os.clock` (CPU seconds, sub-microsecond resolution) because
`host.monotonic_ms` is a whole millisecond and most of these calls are far below it; the codemode,
mesh, fabric and operation numbers are the benches' own clocks (wall), as their headers say.

## The table

One row per seam. "Per turn" means: the crossing count and bytes of one `build_context` over a
60-turn session plus the turn's own reads, measured in `scripts/bench-seams.lua` (row
`turn.context_build`); where a row is not on that path the count says what it is instead.

| # | seam | where (both sides) | what crosses | shape | sync/async | who blocks or polls | per turn | bytes/call | JSON vs work | p50 / p99 | gain if WIT + async | cost (lines, risk) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | Lua core <-> Rust host (capability calls and their answers) | `lua/core/memory.lua:28` (every `query`/`exec` decodes) <-> `rust/wa-host/src/main.rs:463` (the `host` table), `rust/wa-capabilities/src/capabilities.rs:110` (the 131-entry REGISTRY), `rust/wa-capabilities/src/host.rs` (61 `push_json` answer sites) | arguments and answers | JSON text both ways; the doc on each capability says "answers JSON text ... never a Lua table" | sync (C ABI: the interpreter is inside the call) | the Lua thread, for the call | 1108 calls, 4,675,186 B back | floor 1.0 us; `read_file` 8 us for 4,200 B | sql answers are 428,706 B of an `429 ms` context build; Lua decodes at ~17.8 MB/s, so ~24 ms (5.6%) is JSON; tool results are plain text (no JSON) | floor 1.0 / 2.0 us; `read_file` 8 / 11 us | typed answers for the sql shape (row 9) ~24 ms per build; async buys nothing in one interpreter - there is no second consumer to run | ~60 lines for row 9's part; the other 130 capabilities keep their documented shape |
| 2 | CodeAct run blocks <-> `tools.*` | `lua/core/codemode.lua:549` (`native_run`), `:679` (`component_run`), `:500` (`pending_calls.invoke`) <-> `rust/wa-capabilities/src/codemode_seam.rs`, `wit/codemode/codemode.wit` (`args-json`/`result-json`) | one scripted tool call | JSON text (the WIT itself carries the JS values as `*-json`) | sync: the block waits on the answer (`wait_s` budget) | the block, until the tool answers | 22 crossings per script (native), 13 (component) | not isolated - see "not measured" | not measured (the guest VM is not in these numbers) | 97-170 ms median per script native, 67-236 ms component; RSS 36.3 vs 46.1 MB | the guest is the cost, not the seam: the component saves 9 crossings and costs +10 MB RSS; no JSON win is measurable until the guest is provisioned | high: `codemode_seam.rs` is 906 lines and the guest contract is not arbitrary to change |
| 3 | node <-> node (relay, mesh, operations, remote-pending) | `lua/core/binding.lua:204` (`host.mesh_call`) <-> `rust/wa-capabilities/src/mesh_host.rs`, `rust/wa-rendezvous/src/relay_client.rs`, `rust/wa-capabilities/src/serve.rs:2533` (run route), `rust/wa-fabric`, `wit/mesh/mesh.wit`, `wit/fabric/fabric.wit` | roster/grant documents, signed tickets, offers, relayed requests | JSON text into the host; WIT records between components (`wit/mesh`), and `wit/fabric` already says `async func` + `stream<heartbeat>` | sync on the native path; the fabric's own WIT is already the async shape | the caller; the relay poll lane ticks every 250 ms (`binding_runtime.rs:260`) and the poll lane every 2 s (`:311`) | 0 in a single-node turn (measured: no `mesh_call`/`fabric_call` in the context build) | mesh: 34.2 us native `verify_ticket`; fabric: one offer RTT 2,000 B-ish on loopback p50 70 us | not JSON-bound: a decision is 0.2-0.3 us native, 120 us through the component | mesh component `decide` p50 120.3 / p99 139.6 us vs native ~0.2 us; first call 175.4 ms (compile+instance); RSS 6,568 -> 24,784 KB | none for a single node; keep native, and the fabric's async shape stays fabric-transport's | belongs to fabric-transport (audited here, migrated there) |
| 4 | node <-> rendezvous (bindings, polls) | `lua/core/binding.lua:8,49,70` (`host.binding_state`) <-> `rust/wa-capabilities/src/host.rs:1434`, `rust/wa-rendezvous/src/binding_runtime.rs` | the binding state, a relay request | JSON text (24 B) | sync read; a background poll lane | the lane sleeps 250 ms between relay checks and 2 s between idle polls (`binding_runtime.rs:260,286,311`); no interpreter block | 5-7 reads per turn | 24 B | 1 us total; Lua decode 3 us | 1.0 / 2.0 us | the read is already ~free; a future per bind would remove up to 2 s of bind latency, not throughput | low for the read; the poll lane belongs to fabric-transport |
| 5 | node <-> wa-vault (HTTP) | `lua/core/vault.lua:47` (GET /status), `:70` (every call) <-> `rust/wa-vault` (the engine), `rust/wa-kernel-runtime/src/vault_host.rs` | headers, an envelope, and the body inside it (two JSON layers) | JSON over HTTP | sync | the interpreter, for the round trip | 0-1 per credential decision, not per turn | 29 B in, 96 B out | 112 us p50 total, 37 us of it Lua JSON (33%) | 112 / 713 us (loopback stub, n=100) | none worth taking: HTTP is the external contract, so JSON stays; dropping the inner encode would save ~37 us | 0 - external contract |
| 6 | provider adapters (stream parsing) | `lua/core/provider.lua:1393` (`host.http_stream`) <-> `rust/wa-capabilities/src/host.rs:2404` (`http_stream`), `:2464` (`http_sse`, one line per callback) | the request, then the aggregated completion (content, tool_calls, usage) | JSON text | sync: the whole model call happens inside the capability (`host.rs:2167` says so) | the interpreter, for the whole model call; `http_sse` gives a line callback for other dialects | 2 `http_stream` per fallback turn | 3,659 B back in that turn | decode rate 17.8 MB/s => bounded ~1.1 ms per 20 KB completion (the only JSON on the path; framing is Rust's) | 2 calls, not isolated per call | a `stream<chunk>` seam would let the turn render as it arrives and drop the aggregate copy | high: `provider.lua` is 1,751 lines and the stream contract is the model's |
| 7 | MCP connectors | `lua/core/mcp.lua:1053` (`host.component_mcp`), `:1164` (`operation start`), `:1167` (`operation await`) <-> `rust/wa-kernel-runtime/src/components.rs:651`, `rust/components/mcp-whatsapp`, `mcp-echo`, `wit/seams/seams.wit` (`mcp-server.call-tool`) | the request, the component's answer, and an operation handle per call | JSON text + the operation table | sync: `await` blocks with a 250 ms wake | the interpreter, for the connector's whole run (`timeout_seconds` up to 3,600) | 0 without MCP; 3 crossings per MCP tool call | not measured - SKIPPED, no server configured (`invalid_component_name`) | not measured | bounded by row 8 | `call-tool` as a future removes the start/await pair; measured cost of that pair is row 8 | medium (`mcp.lua` 1,485 lines) |
| 8 | operation table | `lua/core/mcp.lua:1164`, `lua/core/tool_progress.lua:372` (`host.operation`, 26 call sites) <-> `rust/wa-capabilities/src/host.rs:1378`, `rust/wa-capabilities/src/operations.rs` (2,844 lines), `rust/wa-operation` | action + arguments, then the operation's state | JSON text | sync; `await` loops on `manager().wait(id, 250 ms)` (`operations.rs:1521`) | the interpreter, for the operation's life, waking every 250 ms | 0 in a plain turn; 2 per MCP call | 92 B in, 43 B out | 761 us of which 15 us JSON - the cost is the spawn and the wait, not the encoding | start+await 761 / 4,855 us for `sh -c true`; phases bench total p50 84 ms (3 samples, unattributed 1 ms) | an `await` future removes the 4 wakes/s and the blocked interpreter | medium: `control()` is one place |
| 9 | session journal / memory.db writes | `lua/core/memory.lua:28` (`query`), `:1336` (the insert), `:1424` (`session_messages`: `SELECT *` over a window) <-> `rust/wa-capabilities/src/host.rs:519` (`sql_exec`), `:629` (`sql_query`); the component path's typed shape is `wit/kernel/sql.wit` + `rust/components/memory` | rows | JSON text on the native path; a typed `value` variant on the component path | sync | the interpreter, for the query | 34 `sql_query` + 4 `sql_exec` per context build; 93 + 93 in the fallback turn | 428,706 B of query answers per build; one 50-row read 47,148 B | read 3,307 us p50 of which Lua decode 2,647 us (80%); serde parses the same bytes in 99.9 us; write 153 us of which 41 us JSON | read 3,307 / 4,550 us; write 153 / 249 us; `append_turn` 451 / 900 us | typed rows (WIT's own `value` shape on the native ABI): ~2.6 ms per 47 KB read, ~24 ms per context build; async: none measurable | ~60 lines: Rust fn + registry + `docs/HOST.md` row + Lua switch + parity test |
| 10 | TUI <-> core event path | `lua/core/cli_view.lua`, `cli_panel.lua` (`host.transcript_*`) <-> `rust/wa-capabilities/src/host.rs:4368` (`transcript_write`), `rust/wa-term`; the web UI by `rust/wa-capabilities/src/serve.rs:2533` (SSE) | text lines (terminal), JSON events (web) | plain text - no JSON on the terminal path | sync, and it is a write (no poll) | nobody: a write returns | many small writes per turn | 1,110 B per line | no JSON to remove | 2 us p50 / 43-105 us p99 (a frame redraw when the editor is up) | nothing: the terminal path carries no JSON | 0 |
| - | `host.bus_publish` (the Lua bus calls reach no capability) | `lua/core/run_failure.lua:227`, `provider.lua:1017`, `update_banner.lua:668` | a fact, as JSON | the calls are guarded (`if host.bus_publish then`) and no Rust code registers that name (`rg bus_publish rust/` is empty) | n/a | n/a | 0 (dead) | 0 | - | - | this is a missing seam, not an expensive one: the durable event path already exists (the journal), the live one does not | small to wire, and it needs a decision first |

## What the numbers say

1. **The one seam that costs real time every turn is the journal read** (row 9): 3.3 ms p50 for a
   50-row `SELECT *` window, and 2.6 ms of it is the pure-Lua JSON decoder chewing 47 KB. serde
   parses the same bytes in 100 us. Per context build this is 428,706 B of sql answers across 34
   queries, and at the measured decode rate that is ~24 ms of a 429 ms build spent turning typed rows
   into JSON text and back into a Lua table.
2. **The rest of the internal seams are microseconds.** The crossing floor is 1 us; a 4 KB tool result
   is 8 us; the binding read is 1 us; a transcript line is 2 us. Moving any of them to WIT + async
   would be a real change with no measurable gain, which is exactly what the law says not to do.
3. **Two seams block for a long time, and both are process-shaped, not JSON-shaped**: the provider
   call (row 6, the interpreter is inside `http_stream` for the whole model call) and
   `operation await` (row 8, a 250 ms wake loop while the interpreter is blocked). Their fix is the
   async shape the rule names - but it buys latency under concurrency, not bytes, and neither has a
   measured JSON problem.
4. **Bigger than JSON on row 1: 4.2 MB of file reads per context build.** 311 `read_file` calls and
   289 `sha256` calls, 4,202,798 B back. That is not a seam problem (a file read is bytes, and the
   text is the tool's own result); it is a prompt-assembly caching problem, and it is 8x the sql
   bytes. Recorded here so nobody "optimises" the seam while the real cost sits next to it.
5. **The component paths are slower per call and heavier per process, as measured before**: mesh
   `decide` 120 us against ~0.2 us native, first call 175 ms, +18 MB RSS; codemode +10 MB RSS and
   9 fewer crossings. A component is justified by swapping a rule without a rebuild, never by
   latency - the numbers say so on this machine.

## Order of migration (biggest measured gain per line first)

1. **Row 9, the journal read: typed rows on the native ABI** (the shape `wit/kernel/sql.wit` already
   describes). ~2.6 ms per 47 KB read, ~24 ms per context build, ~60 lines, reversible, no wire
   change, and the component path keeps its WIT records untouched. **Migrated in phase 2 - see the
   log below.**
2. Row 8, `operation await` as a future: removes 4 wakes/s and the blocked interpreter. Worth doing
   by whoever owns `operations.rs`, not first.
3. Row 7, MCP `call-tool` as a future: removes the start/await pair per call; same owner.
4. Row 6, provider streaming as `stream<chunk>`: bounded ~1.1 ms per 20 KB of aggregate decode; a
   streaming rewrite of 1,751 lines is not paid for by 1 ms.
5. Rows 3 and 4 (node <-> node, rendezvous): belong to fabric-transport, measured ~0 per single-node
   turn here, and the fabric's WIT is already the async shape.
6. Row 5 (vault) and row 10 (TUI): JSON stays / there is none to remove.
7. Row 2 (CodeAct): the guest is the cost; no seam change is measurable until the guest VM is
   provisioned.

## JSON that stays

Row 5 (the vault's HTTP door) and row 6's request body are the outside world's format; the MCP
connector's payloads are MCP's (row 7); `wit/seams/seams.wit` already declares `mcp-server` as
`string` in/out for exactly that reason. Nothing in this audit proposes to change them.

## Premises the brief or the tree had wrong

1. **`scripts/bench-core-calls.lua`'s premise was stale** - "hide `WASM_AGENT_LLM_API_KEY`,
   `..._BASE_URL`, `..._MODEL` and the turn takes the local fallback" - because the shipped provider
   list carries a default route, so `configured()` answered true with no environment at all and the
   counting run refused instead of counting. Fixed in `8ae79507` by pinning the module's own
   `_pinned` switch to empty settings; the counts in this report are from the fixed run.
2. **`host.bus_publish` is referenced by three Lua call sites and registered by nothing.** The
   guards make it harmless, and it means the "live event" half of the TUI path does not exist today;
   the terminal path is `host.transcript_*` and the web path is `serve.rs`' SSE.
3. The brief asks for "async" on every seam. Measured: only rows 6 and 8 actually block for long, and
   neither is JSON-bound; making the microsecond seams async would add machinery and no measured win.

## Not measured, and why

- **CodeAct's JSON share** and the per-call bytes: `scripts/bench-codemode.sh`'s own header says the
  guest VM is not provisioned in this checkout, so both paths run the same scripted protocol peer.
  The numbers in row 2 are the loop, the boundary and the copies - not the guest.
- **The MCP component call** (row 7): no MCP server is configured on this node, so the row is a SKIP
  with its reason (`invalid_component_name`), not a zero.
- **`scripts/bench-core-bridge.sh`** (native vs agent-core component crossings): it needs
  `agent_core.wasm`, and `scripts/build-agent-core.sh` refuses on this node with
  `wasi-sdk not found (set WASI_SDK)`. Named, not guessed.
- **A real relay/mesh round trip**: no peer exists in this mission, so the node <-> node row carries
  the loopback offer RTT (70 us p50) and the per-call decision costs, not a WAN number.
- **`bench-hooks.sh`, `bench-selfloop.sh`, `bench-memory-component.sh`, `bench-model-gateway.sh`**:
  not re-run in this round. Their seams were migrated by earlier missions and their numbers belong to
  those reports; re-running them would not change this table's order.

## Text this branch adds to operator/model-facing surfaces

1. `scripts/bench-seams.sh`'s usage line: `usage: bash scripts/bench-seams.sh [--iterations N] [--json]`
2. `scripts/bench-seams.sh`'s failure line: `FAIL no wa binary (build it, or set WA_BIN)`
3. Its serde-skip line: `SKIP the serde half: the example did not run here (see below); the Lua half above stands on its own`
4. Its run header: `bench: seams (bin=..., iterations=..., home=...)`
5. `scripts/bench-seams.lua`'s SKIP lines for MCP and for a missing `host.operation`, printed verbatim
   with their reasons, and the `turn.context_build` header row.
6. `scripts/bench-seams-vault-stub.mjs`'s 404 body: `{"error":{"code":"not_found","message":"bench stub answers /status only"}}`
7. `rust/wa-host-support/examples/json-cost.rs`'s refusal: `json-cost: no *.json payload in <dir> - a check that measures nothing is not a pass`

## Phase 2 log

(one seam per commit, before/after from the same benchmark; added as each lands)

