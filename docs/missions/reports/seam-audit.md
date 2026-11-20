# Seam audit: every internal seam, measured

Branch `wa/seam-audit-report` (split from `change/race-seam-audit-W` by review r1). Phase 1 of the
brief: inventory + measurement, **no production code** - this branch carries the report and the
benchmarks that produced it; the one migration the audit recommends is in `wa/sql-rows`. The only file
it adds under `rust/` is `wa-host-support/examples/json-cost.rs`, a dev example no shipped artifact
compiles (examples are their own cargo target); every runtime crate is byte-identical to
`origin/main`.

Every number below was measured in this worktree, on this node (avell, 16 cores, linux x86_64), in a
scratch `WASM_AGENT_HOME` and a scratch ledger, with the tree's own `wa` binary. Nothing here touched a
live node, the fleet, a real provider or the operator's ledger.

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
`rust/wa-host-support/examples/json-cost.rs`, commit `5823d3dc`; the turn-loop and vault rows in
`ce867fae`). Building it forced one stale premise out of `scripts/bench-core-calls.lua`, fixed in
`5823d3dc` - see "Premises the brief or the tree had wrong" below.

**Which binary, which clock.** p50/p99 in `scripts/bench-seams.lua` are of `os.clock` - **CPU clock on
avell** - because `host.monotonic_ms` is a whole millisecond and most of these calls are far below it;
the codemode, mesh, fabric and operation numbers are those benches' own clocks (wall), as their
headers say. The table's `bench-seams` rows are the run at commit `353a3ca2`, whose `wa --build-info`
answered `commit=353a3ca2 dirty=false` when it was built. The component rows were measured earlier in
this tree with components built from it; `git diff 353a3ca2..HEAD -- rust/ lua/ scripts/` is empty, so
the code those runs measured is this branch's code and only report text came after.

The per-turn row (`bench-core-calls.lua`) was run on the same binary: `one turn: ok in 7452 ms, 3158 host
calls, 10590223 bytes back` - `read_file` 760 calls (10,471,247 B), `getenv` 1034 (32,843 B), `sha256` 840
(53,760 B), `sql_exec` 94, `sql_query` 93 (13,741 B). It is the local-fallback turn, which loops, so it
is the state-and-tool half of a turn and not one model call; the `turn.context_build` row below is the
once-per-model-call half.

## The table

One row per seam. "Per turn" means: the crossing count and bytes of one `build_context` over a
60-turn session plus the turn's own reads, measured in `scripts/bench-seams.lua` (row
`turn.context_build`); where a row is not on that path the count says what it is instead.

| # | seam | where (both sides) | what crosses | shape | sync/async | who blocks or polls | per turn | bytes/call | JSON vs work | p50 / p99 | gain if WIT + async | cost (lines, risk) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | Lua core <-> Rust host (capability calls and their answers) | `lua/core/memory.lua:32` (every `query`/`exec` decodes) <-> `rust/wa-host/src/main.rs:463` (the `host` table), `rust/wa-capabilities/src/capabilities.rs:110` (the REGISTRY: 141 capabilities here, 142 in `wa/sql-rows`, bound to 131 `pub extern "C-unwind" fn`), `rust/wa-capabilities/src/host.rs` (61 `push_json` answer sites) | arguments and answers | JSON text both ways; the doc on each capability says "answers JSON text ... never a Lua table" | sync (C ABI: the interpreter is inside the call) | the Lua thread, for the call | 1125 calls, 4,801,780 B back | floor 1.0 us; `read_file` 4 us for 4,200 B | sql answers are 428,682 B of a `117 ms` context build; Lua decodes at ~17.8 MB/s, so ~24 ms (20%) is JSON; tool results are plain text (no JSON) | floor 1.0 / 1.0 us; `read_file` 4 / 5 us | typed answers for the sql shape (row 9) ~24 ms per build; async buys nothing in one interpreter - there is no second consumer to run | ~136 lines in `wa/sql-rows` for row 9's part; the other capabilities keep their documented shape |
| 2 | CodeAct run blocks <-> `tools.*` | `lua/core/codemode.lua:549` (`native_run`), `:679` (`component_run`), `:500` (`pending_calls.invoke`) <-> `rust/wa-capabilities/src/codemode_seam.rs`, `wit/codemode/codemode.wit` (`args-json`/`result-json`) | one scripted tool call | JSON text (the WIT itself carries the JS values as `*-json`) | sync: the block waits on the answer (`wait_s` budget) | the block, until the tool answers | 22 crossings per script (native), 13 (component) | not isolated - see "not measured" | not measured (the guest VM is not in these numbers) | 97-170 ms median per script native, 67-236 ms component; RSS 36.3 vs 46.1 MB | the guest is the cost, not the seam: the component saves 9 crossings and costs +10 MB RSS; no JSON win is measurable until the guest is provisioned | high: `codemode_seam.rs` is 906 lines and the guest contract is not arbitrary to change |
| 3 | node <-> node (relay, mesh, operations, remote-pending) | `lua/core/binding.lua:204` (`host.mesh_call`) <-> `rust/wa-capabilities/src/mesh_host.rs`, `rust/wa-rendezvous/src/relay_client.rs`, `rust/wa-capabilities/src/serve.rs:2533` (run route), `rust/wa-fabric`, `wit/mesh/mesh.wit`, `wit/fabric/fabric.wit` | roster/grant documents, signed tickets, offers, relayed requests | JSON text into the host; WIT records between components (`wit/mesh`), and `wit/fabric` already says `async func` + `stream<heartbeat>` | sync on the native path; the fabric's own WIT is already the async shape | the caller; the relay poll lane ticks every 250 ms (`binding_runtime.rs:260`) and the poll lane every 2 s (`:311`) | 0 in a single-node turn (measured: no `mesh_call`/`fabric_call` in the context build) | mesh: 34.2 us native `verify_ticket`; fabric: one offer RTT on loopback p50 70 us | not JSON-bound: a decision is 0.2-0.3 us native, 120 us through the component | mesh component `decide` p50 120.3 / p99 139.6 us vs native ~0.2 us; first call 175.4 ms (compile+instance); RSS 6,568 -> 24,784 KB | none for a single node; keep native, and the fabric's async shape stays fabric-transport's | belongs to fabric-transport (audited here, migrated there) |
| 4 | node <-> rendezvous (bindings, polls) | `lua/core/binding.lua:8,49,70` (`host.binding_state`) <-> `rust/wa-capabilities/src/host.rs:1434`, `rust/wa-rendezvous/src/binding_runtime.rs` | the binding state, a relay request | JSON text (24 B) | sync read; a background poll lane | the lane sleeps 250 ms between relay checks and 2 s between idle polls (`binding_runtime.rs:260,286,311`); no interpreter block | 5-7 reads per turn | 24 B | 1 us total; Lua decode 3 us | 1.0 / 2.0 us | the read is already ~free; a future per bind would remove up to 2 s of bind latency, not throughput | low for the read; the poll lane belongs to fabric-transport |
| 5 | node <-> wa-vault (HTTP) | `lua/core/vault.lua:47` (GET /status), `:70` (every call) <-> `rust/wa-vault` (the engine), `rust/wa-kernel-runtime/src/vault_host.rs` | headers, an envelope, and the body inside it (two JSON layers) | JSON over HTTP | sync | the interpreter, for the round trip | 0-1 per credential decision, not per turn | 29 B in, 96 B out | 365 us p50 total, 36 us of it Lua JSON (10%) | 365 / 480 us (the bench stub on loopback, n=200) | none worth taking: HTTP is the external contract, so JSON stays; dropping the inner encode would save ~37 us | 0 - external contract |
| 6 | provider adapters (stream parsing) | `lua/core/provider.lua:1393` (`host.http_stream`) <-> `rust/wa-capabilities/src/host.rs:2404` (`http_stream`), `:2464` (`http_sse`, one line per callback) | the request, then the aggregated completion (content, tool_calls, usage) | JSON text | sync: the whole model call happens inside the capability (`host.rs:2167` says so) | the interpreter, for the whole model call; `http_sse` gives a line callback for other dialects | 2 `http_stream` per fallback turn | 3,659 B back in that turn | decode rate 17.8 MB/s => bounded ~1.1 ms per 20 KB completion (the only JSON on the path; framing is Rust's) | 2 calls, not isolated per call | a `stream<chunk>` seam would let the turn render as it arrives and drop the aggregate copy | high: `provider.lua` is 1,751 lines and the stream contract is the model's |
| 7 | MCP connectors | `lua/core/mcp.lua:1053` (`host.component_mcp`), `:1164` (`operation start`), `:1167` (`operation await`) <-> `rust/wa-kernel-runtime/src/components.rs:651`, `rust/components/mcp-whatsapp`, `mcp-echo`, `wit/seams/seams.wit` (`mcp-server.call-tool`) | the request, the component's answer, and an operation handle per call | JSON text + the operation table | sync: `await` blocks with a 250 ms wake | the interpreter, for the connector's whole run (`timeout_seconds` up to 3,600) | 0 without MCP; 3 crossings per MCP tool call | not measured - SKIPPED, no server configured (`invalid_component_name`) | not measured | bounded by row 8 | `call-tool` as a future removes the start/await pair; measured cost of that pair is row 8 | medium (`mcp.lua` 1,485 lines) |
| 8 | operation table | `lua/core/mcp.lua:1164`, `lua/core/tool_progress.lua:372` (`host.operation`, 26 call sites) <-> `rust/wa-capabilities/src/host.rs:1378`, `rust/wa-capabilities/src/operations.rs` (2,844 lines), `rust/wa-operation` | action + arguments, then the operation's state | JSON text | sync; `await` loops on `manager().wait(id, 250 ms)` (`operations.rs:1521`) | the interpreter, for the operation's life, waking every 250 ms | 0 in a plain turn; 2 per MCP call | 92 B in, 43 B out | 811 us of which 16 us JSON - the cost is the spawn and the wait, not the encoding | start+await 811 / 4,170 us for `sh -c true`; phases bench total p50 84 ms (3 samples, unattributed 1 ms) | an `await` future removes the 4 wakes/s and the blocked interpreter | medium: `control()` is one place |
| 9 | session journal / memory.db writes | `lua/core/memory.lua:32` (`query`), `:1336` (the insert), `:1424` (`session_messages`: `SELECT *` over a window) <-> `rust/wa-capabilities/src/host.rs:519` (`sql_exec`), `:629` (`sql_query`); the component path's typed shape is `wit/kernel/sql.wit` + `rust/components/memory` | rows | JSON text on the native path; a typed `value` variant on the component path | sync | the interpreter, for the query | 34 `sql_query` + 4 `sql_exec` per context build; 93 + 94 in the fallback turn | 428,682 B of query answers per build; one 50-row read 47,145 B | read 3,437 us p50 of which Lua decode 2,783 us (81%); serde parses the same bytes in 99.9 us; write 162 us of which 29 us JSON | read 3,437 / 4,494 us; write 162 / 258 us; `append_turn` 477 / 950 us | **MIGRATED on this branch (`253d666c`)**: the rows answer as a Lua table, WIT's own `value` shape on the native ABI, and `memory.query()` - the reader behind **41 `query(` call sites** - takes it: 3,437 -> **647 us p50** per 47 KB read (p99 4,494 -> 1,839), JSON text per context build 428,682 B -> **305 B**; async: none measurable | ~136 lines of Rust + registry + `docs/HOST.md` + a 12-line Lua switch + a 131-line parity test |
| 10 | TUI <-> core event path | `lua/core/cli_view.lua`, `cli_panel.lua` (`host.transcript_*`) <-> `rust/wa-capabilities/src/host.rs:4368` (`transcript_write`), `rust/wa-term`; the web UI by `rust/wa-capabilities/src/serve.rs:2533` (SSE) | text lines (terminal), JSON events (web) | plain text - no JSON on the terminal path | sync, and it is a write (no poll) | nobody: a write returns | many small writes per turn | 1,110 B per line | no JSON to remove | 3 us p50 / 79 us p99 (a frame redraw when the editor is up) | nothing: the terminal path carries no JSON | 0 |
| - | `host.bus_publish` (the Lua bus calls reach no capability) | `lua/core/run_failure.lua:227`, `provider.lua:1017`, `update_banner.lua:668` | a fact, as JSON | the calls are guarded (`if host.bus_publish then`) and no Rust code registers that name (`rg bus_publish rust/` is empty) | n/a | n/a | 0 (dead) | 0 | - | - | this is a missing seam, not an expensive one: the durable event path already exists (the journal), the live one does not | small to wire, and it needs a decision first |

## What the numbers say

1. **The one seam that costs real time every turn is the journal read** (row 9): 3.4 ms p50 for a
   50-row `SELECT *` window, and 2.8 ms of it is the pure-Lua JSON decoder chewing 47 KB. serde
   parses the same bytes in 100 us. Per context build this is 428,682 B of sql answers across 34
   queries, and at the measured decode rate that is ~24 ms of a 117 ms build spent turning typed rows
   into JSON text and back into a Lua table. **On this branch it is not paid at all**: the same read
   answers in 552 us p50 and the JSON text a context build pulls back falls from 428,682 B to 305 B
   (Phase 2 log below). `memory.query()` is the reader for **41 `query(` call
   sites** in `lua/core/memory.lua` - the transcript window, sessions, recall and the counts - so the
   decode is paid on every one of them, not only on the turn's transcript read.
2. **The rest of the internal seams are microseconds.** The crossing floor is 1 us; a 4 KB tool result
   is 8 us; the binding read is 1 us; a transcript line is 2 us. Moving any of them to WIT + async
   would be a real change with no measurable gain, which is exactly what the law says not to do.
3. **Two seams block for a long time, and both are process-shaped, not JSON-shaped**: the provider
   call (row 6, the interpreter is inside `http_stream` for the whole model call) and
   `operation await` (row 8, a 250 ms wake loop while the interpreter is blocked). Their fix is the
   async shape the rule names - but it buys latency under concurrency, not bytes, and neither has a
   measured JSON problem.
4. **Bigger than JSON on row 1: 4.2 MB of file reads per context build.** 315 `read_file` calls and
   290 `sha256` calls, 4,329,066 B back. That is not a seam problem (a file read is bytes, and the
   text is the tool's own result); it is a prompt-assembly caching problem, and it is 8x the sql
   bytes. Recorded here so nobody "optimises" the seam while the real cost sits next to it.
5. **The component paths are slower per call and heavier per process, as measured before**: mesh
   `decide` 120 us against ~0.2 us native, first call 175 ms, +18 MB RSS; codemode +10 MB RSS and
   9 fewer crossings. A component is justified by swapping a rule without a rebuild, never by
   latency - the numbers say so on this machine.

## Order of migration (biggest measured gain per line first)

1. **Row 9, the journal read: typed rows on the native ABI** (the shape `wit/kernel/sql.wit` already
   describes). ~2.8 ms per 47 KB read, ~24 ms per context build, ~136 lines, reversible, no wire
   change, and the component path keeps its WIT records untouched. **In `wa/sql-rows`, not here.**
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
   counting run refused instead of counting. Fixed in `5823d3dc` by pinning the module's own
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

## The gate, and what it said

Run on this node under `flock -o /home/victor/Work/missions/.suite.lock` (the node's one suite lock -
other missions were running suites on the same 16 cores), with the tree's own binary at
`da19722a`, whose `wa --build-info` answered `commit=da19722a... dirty=false` when it was built.

**`scripts/fast.sh --jobs 4` at the final head: 305 checks, 2 failed, 0 skipped (282 s).** Both
failures are the environment's, and both are proven rather than asserted:

1. `scripts/test-refusal-contract.lua:24: lua/core/refusal_codes.lua is stale` - **pre-existing on
   `origin/main`**: `git archive origin/main | tar -x -C /tmp/base-main`, then
   `lua5.4 scripts/gen-refusal-codes.lua --check` in that pristine tree exits 1 with the same message,
   and the same command on both branches exits 1 with the same message.
2. `rust wa-capabilities (exit 101)`: `operations::adoption_survives_the_relay_deadline` and
   `operations::await_returns_at_its_own_wait` panic at once. They are not broken and not this
   branch's: both tests refuse to run unless `HOME` is a scratch directory ("this test starts real
   operations, so HOME must be a scratch or temp directory"); the fast path does not set one, the full
   gate does. **Same binary, same tree, only `HOME` changed**: with `HOME=$(mktemp -d)` the whole
   crate passes - `test result: ok. 345 passed; 0 failed` (`cargo test --release -p wa-capabilities
   --lib`). The crate this branch changes is therefore green; the fast path's row turns red because it
   does not own the environment those two tests demand.

**The parity test this branch adds is in the fast path and passed there**: `sql rows ok (11 checks, 0
skipped)` - both when run alone (`WA_SCRIPT=scripts/test-sql-rows.lua`) and as a fast-path row, at
the final head, after the r2 probes and the non-finite REAL fix.

**`scripts/test.sh` (the full gate): stops at `scripts/test-sentinel-service-deploy.cjs:23`** -
`Expected ['stop','copy','start'], actual ['stop']` - **pre-existing on `origin/main`**: the same
script run in the pristine base tree fails with the same assertion, and the gate invokes it
unconditionally (`scripts/test.sh:243`) on linux, where it is a Windows-deploy proof. The gate exits at
its first failure, so the rows after it did not run - on this branch, on the report branch, or on main.
The rust rows before it passed (134 + 18 + 0, all ok). That run was made before this round's rebase
(review r2); nothing under `rust/` or `lua/` changed after it except the non-finite REAL branch and the
parity test, so its verdict is about the same code - but it was **not** re-run after them, so the full
gate's verdict for the final head is unknown beyond the build and the fast path above. Said rather than
implied.

## Text this branch adds to operator/model-facing surfaces

1. `scripts/bench-seams.sh`'s usage line: `usage: bash scripts/bench-seams.sh [--iterations N] [--json]`
2. `scripts/bench-seams.sh`'s refusal when the tree has no binary - four lines, verbatim:

   ```
   FAIL no wa binary from this tree (looked at ${CARGO_TARGET_DIR:-<unset>}/release/wa and $ROOT/rust/target/release/wa).
        Build it:  (in rust/) CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-<dir>} cargo build --release --offline -p wa-host
        Or name one: WA_BIN=<path> bash scripts/bench-seams.sh
        A binary from PATH is refused on purpose: a table measured against another tree's code is not this tree's.
   ```

3. Its serde-skip line: `SKIP the serde half: the example did not run here (see below); the Lua half above stands on its own`
4. Its run header - both lines, verbatim:

   ```
   bench: seams (bin=$bin, binary-commit=$stamp, iterations=${iterations:-200}, home=$home)
   bench: seam rows are os.clock (CPU) on this machine; codemode/mesh/fabric are those benches' own clocks
   ```

5. `scripts/bench-seams.lua`'s SKIP lines, verbatim, with their reasons: the MCP row
   (`SKIP:no MCP server configured (invalid_component_name)`), the missing-capability row
   (`SKIP:no host.operation capability`) and the vault row
   (`SKIP:no stub vault (pass WA_SEAM_VAULT_URL=<loopback stub>; an inherited WASM_AGENT_VAULT_URL is cleared, never measured)`),
   plus the `turn.context_build` header row.
6. `scripts/bench-seams-vault-stub.mjs`'s 404 body: `{"error":{"code":"not_found","message":"bench stub answers /status only"}}`
7. `rust/wa-host-support/examples/json-cost.rs`'s refusal: `json-cost: no *.json payload in <dir> - a check that measures nothing is not a pass`

## Phase 2 log

### Row 9 - the journal read, migrated (`253d666c`)

**What changed.** `host.sql_rows(sql, params_json)` (`rust/wa-capabilities/src/host.rs`) answers the
same rows as `host.sql_query` from the same reader (`read_cells`, now shared by both), as a Lua
table: INTEGER as a Lua integer, REAL as a float, TEXT as a string, BLOB as the `<N bytes>`
placeholder, NULL as an absent key, and a failure as `nil, error`. `lua/core/memory.lua`'s
`query()` takes it when the host has it and keeps the JSON path on a host without it, so an older
binary is unaffected. The record shape is `wit/kernel/sql.wit`'s `value` variant - this is that shape
on the native ABI, where the alternative is text plus a decoder.

**The claim, corrected (review r2).** `memory.query()` is not only the turn loop's transcript read: it
is the one reader behind **41 call sites** in `lua/core/memory.lua` - the transcript window
(`session_messages`), `session`/`sessions`, the recall and search paths, the counts, and the schema
probes. (A naive `query(` grep counts 45; two of those are `fts_query()`, one is the local
definition and one is the `host.sql_query` fallback.) Every one of the 41 stops decoding JSON text on
this branch; the before/after below is the transcript window because that is the largest payload, not
because it is the only site.

**Parity, on the path real use takes** (rule 14): `scripts/test-sql-rows.lua`, **11 checks**, wired the way the tree
already wires tests - the full gate runs every `tests/*.lua`, and `scripts/fast.sh` runs every
`scripts/test-*.lua` not in `scripts/fast-path.exclude`, so this file is in the fast path by default
(it creates its own scratch home and refuses the operator's). It compares:

1. every SQLite type - INTEGER, REAL, TEXT carrying UTF-8, BLOB, NULL - plus empty string and zero,
   value by value **and** by Lua number type (`5` and `5.0` concatenate differently);
2. a failing statement: `{error}` from the JSON path, `nil, error` from the typed one, naming the same
   reason;
3. bound parameters;
4. the turn loop's own window over a 20-turn seeded session (`SELECT * ... LIMIT ?`);
5. the switch itself - with `host.sql_query` made to raise, `memory.session_messages` still returns its
   20 rows and still decodes `tool_calls`/`trace`, which is only possible through the typed path;
6. the shapes that are easy to get wrong (review r2): integers at 2^53+1 and math.mininteger come
   back exact and as Lua integers, the two infinities arrive as an absent key on both paths (serde
   writes `null`), text with a NUL byte and text that is not UTF-8 agree, the empty string and blob
   agree, duplicate column names with a NULL agree, an integer above 2^53 in an ARGUMENT is rounded
   identically on both paths (the carrier is `lua/vendor/json.lua`, whose encoder is `%.14g` - pinned
   so a change there is noticed), and `memory.query`'s own failure text is the same on both paths.

**Before/after, same benchmark, same machine** (`bash scripts/bench-seams.sh --iterations 200`, avell,
p50/p99 of `os.clock`, the binary named by `--build-info` in the header):

| row | before (`353a3ca2`, `wa/seam-audit-report`) | after (`da19722a`, this branch) |
| --- | --- | --- |
| `journal.session_messages` p50 | 3,437 us | **647 us** |
| `journal.session_messages` p99 | 4,494 us | **1,839 us** |
| Lua JSON decode of the same 47 KB (measured, now not paid) | 2,783 us | 3,042 us |
| JSON bytes a context build pulls back | 428,682 B (34 `sql_query` calls) | **305 B** (25 `sql_query`) + 9 typed reads |
| `turn.context_build` wall, n=1 | 117 ms | not claimed (83 ms and 258 ms in two runs of the same code, on a machine running other suites - a single sample is not a measurement of this seam) |
| the fallback turn's sql crossings | 93 `sql_query` calls, 13,741 B; no typed read | 54 `sql_query` calls, 3,073 B + 39 typed reads |

The per-read rows are n=200 and are the seam. Two runs of the same code measured 552 / 1,245 us and
647 / 1,839 us p50/p99 for the window - the machine was running other missions' suites for both, and the
number this table carries is the second (the run whose binary stamp, `da19722a`, is a commit on this
branch). The `context_build` wall row is a single sample and is not claimed as the seam's gain.

**What the evidence does not say.** The rows still cross as rows (the same bytes of data); what stopped
is the text encoding of them and the Lua decoder that read it back. Async was not added because this
seam has no second consumer to run while it waits - measured, not assumed.

### Seams that stay, by measurement

| row | why it stays |
| --- | --- |
| 3, 4 (node <-> node, rendezvous) | fabric-transport's seams - audited here, migrated there; measured ~0 per single-node turn, and `wit/fabric` is already `async func` + `stream<heartbeat>` |
| 5 (vault HTTP) | HTTP is the external contract, and the row now measures only the bench's own stub (review r2 MUST 1); the inner encode is 35 us of a 326 us call |
| 6 (provider stream) | bounded ~1.1 ms of aggregate decode per 20 KB completion against a 1,751-line rewrite |
| 7 (MCP) | no server on this node to measure (SKIP, named); its shape is row 8's |
| 8 (`operation await`) | 878 us p50 of which 15 us is JSON: the cost is the spawn, and a future buys concurrency this audit did not measure |
| 10 (TUI) | the terminal path carries no JSON (3 us per line); the web path's SSE is the browser's contract |

**The three strings this branch adds** (the audit branch's seven are unchanged above):

8. The new capability's description, which `wa capabilities --json`, `/health`, `capabilities()` and
   `describe(name)` all read: `Run one read query against this interpreter's own SQLite connection; returns the rows as a Lua table, not JSON text`
9. `docs/HOST.md`'s new section heading `### The rows, as a table or as text` and its four bullets (the
   INTEGER/REAL number-type rule, the `<N bytes>` blob placeholder, NULL as an absent key, `nil, error`
   as the failure shape).
10. The Lua-side refusal reason when a host answers `nil` with no message: `sql_rows_unavailable`.
