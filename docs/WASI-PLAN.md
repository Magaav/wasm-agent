# Going WASI-only: one implementation per feature - the measured plan

Victor, 23/11: *"what if we go WASI default? so just one implementation?"* and *"worthy going omni
device as well as componentizing everything and communicating using WIT ... speeds up the code-factory
by only building the changed components and hotswapping"*.

This page is the plan and the measurements behind it. It is written to be decided on, not to be
agreed with: every number names the command that produced it, the commit it was measured on, and -
where a sub-item could not be measured - says so instead of guessing.

## What was measured where

| | |
| --- | --- |
| machine | `avell`, x86_64 Linux, 16 cores, this laptop (load average 2-8 during the runs) |
| tree | `/home/victor/Work/missions/wasi-only-plan/wt`, branch `change/wasi-only-plan`, base **1cc642f8** (main's tip at the time) |
| binary | this tree's own release build: `cargo build --release -p wa-host --bin wa` with `WA_CODEMODE_BUILD_ASSETS=<checkout>/.git/codemode-assets/pi-1.2.0-quickjs-3.6.2` and `CARGO_TARGET_DIR=<mission target>`; `wa --build-info` identifies it |
| components | the installed set in `~/.wasm-agent/components` **copied** into a scratch `WASM_AGENT_HOME` (read-only for the live node; the resolver verified every pin there, `wa features` printed `component` for the four Lua seams) |
| clock | `os.clock` (CPU seconds, sub-microsecond) for per-call rows; `python time.perf_counter` around whole processes for start rows |

Nothing here ran against a live peer, and nothing was installed.

## 1. The features, as the tree is today

### 1.1 What exists twice

`wa features` on this node reports all eight features `active: component` - that is the *resolver's*
answer, and it is true. What the resolver says and what the **call path** does are two different
things, and the brief's first fact needs that split (`rg -l '<env var>' --glob '!docs/**'`):

| feature | component crate (src lines, test-ish) | WIT seam (lines) | native twin | wired to the call path? |
| --- | --- | --- | --- | --- |
| `memory` | `rust/components/memory` 792 (55) | `wit/memory` 281 | `lua/core/memory.lua` 1941 | **yes** - `lua/core/memory.lua` per operation (`remember`, `recall`, `memories`, `forget`, `retention`, …) |
| `selfloop` | `rust/components/selfloop` 1137 (60) | `wit/selfloop` 524 | `lua/core/selfloop.lua` 1594 | **yes** - `lua/core/selfloop.lua` per operation |
| `hooks` | `rust/components/hooks` 1315 | `wit/hooks` 269 | `lua/core/hooks.lua` 1363 | **yes** - one `decide` per configured hook entry |
| `codemode` | `rust/components/codemode` 1666 (378) | `wit/codemode` 337 | `lua/core/codemode.lua` 1328 | **yes** - `lua/core/codemode.lua` per script step |
| `mesh_component` | `rust/components/mesh` 423 (150) | `wit/mesh` 201 | `rust/wa-mesh` 11246 + `rust/wa-mesh-core` 2558 | **yes** - `rust/wa-mesh/src/seam.rs` reads `WA_MESH_COMPONENT` |
| `gateway` | `rust/components/model-gateway` 509 | `wit/model` 420 | `rust/wa-model-gateway` 5676 | **no** - `WA_MODEL_GATEWAY_COMPONENT` appears in exactly two files: `lua/core/features.lua` and `rust/wa-features/src/lib.rs` |
| `telemetry_sink` | `rust/components/telemetry-sink` 270 | `wit/telemetry` 189 | `rust/wa-telemetry-sink` 3681 | **no** - the env var appears in the same two files only |
| `agent_core` | `rust/components/agent-core` 329 Rust + the vendored Lua 5.4 and the whole `lua/` tree embedded | `wit/kernel` 356 | the binary's own in-process Lua core: `lua/` 93126 lines inside a 79 MB `wa` | **no gate** - `WA_AGENT_CORE_WASM` selects the artifact for `--core-component`/the pool; `WA_AGENT_CORE_COMPONENT` is read only by the resolver |

So of the eight: **five have two implementations kept equal today** (memory, selfloop, hooks, codemode,
mesh), and **three have a component that the node does not route to** (gateway, telemetry_sink,
agent_core). `graph` has no twin at all, as the brief says.

Counting method: `find rust/components/<name>/src -name '*.rs' | xargs wc -l`; the test figure is the
lines after the last `#[cfg(test)]` plus any `tests*.rs` file, so it is a bound, not a parse. WIT:
`find wit/<name> -name '*.wit' | xargs wc -l`.

### 1.2 What one call costs, both ways

Same process, same scratch store, same module: the public function of the Lua gate, 30 samples after 5
warm-ups, `os.clock` per call. Component on is `WA_<FEATURE>_COMPONENT=1`, off is `=0` (the env
override the resolver documents). Milliseconds.

| call | native p50 / p95 | component p50 / p95 | ratio (p50) |
| --- | --- | --- | --- |
| `memory.remember` | 0.060 / 0.073 | 0.619 / 0.691 | 10.3x |
| `memory.recall` | 0.082 / 0.093 | 0.714 / 1.022 | 8.7x |
| `memory.memories` | 0.060 / 0.070 | 0.703 / 0.772 | 11.7x |
| `selfloop.list` | 0.035 / 0.039 | 0.345 / 0.375 | 9.9x |
| `hooks.fire` (one Lua hook registered) | 0.091 / 0.125 | 0.925 / 1.153 | 10.2x |
| `hooks.fire` (nothing configured) | 0.069 / 0.079 | 0.040 / 0.049 | no crossing on either path |

The last row is not a mistake and it matters for the plan: a hook event with nothing configured never
reaches the component (`seam_fire` answers from the merged config and returns before `seam('decide')`),
so the component path is *cheaper* there because it skips building the native engine's entry list. The
wiring is lazy per event, not per feature.

**The floor of one crossing.** Sent an op the guest refuses immediately (`{"op":"wb_no_such_op"}`), the
same way the gate calls it, so the answer is an error after instantiate:

| component | p50 | p95 | `elapsed_ms` the host reports |
| --- | --- | --- | --- |
| memory | 0.204 | 0.223 | n/a (error path) |
| hooks | 0.191 | 0.216 | n/a |
| selfloop | 0.215 | 0.239 | n/a |
| json.encode of a small request (what the gate pays per call) | 0.004 | 0.004 | - |

Where that ~0.20 ms goes, measured in two independent pieces: every dispatch re-reads and re-hashes
the component (`component()` → `load_in` → `fs::read` + SHA-256, `rust/wa-kernel-runtime/src/components.rs`),
and on this laptop the same 207,332-byte `memory.wasm` costs **0.052 ms to read** and **0.099 ms to
SHA-256** (`python3 hashlib` on the same file, SHA-NI, 100 iterations each) - **0.15 ms of the 0.20 ms
floor**. The rest (~0.05 ms) is `Store::new` + `Linker::new` + two `add_to_linker` calls + `instantiate` +
the call. The bigger number for agent-core (below) is the same instantiate on a component with far more
imports.

So the honest statement of the per-call cost is: **~10x native, of which three quarters is the host
re-reading and re-hashing bytes it already has**.

### 1.3 What the component adds to `wa` start

Whole process, wall clock, 9 runs each, same scratch home:

| what | median | min | max |
| --- | --- | --- | --- |
| `wa` + a script that boots `lua/core/memory.lua` and does nothing else | 14.0 ms | 13.4 | 15.2 |
| the same script, one `memory.recall` through the component, `.cwasm` cache warm | **17.0 ms** | 16.3 | 17.8 |
| the same, with the precompiled cache **deleted** (one compile) | 186.5 ms (first run) | 16.1 | 186.5 |
| the same, `WA_COMPONENT_CACHE=0` (compile every process) | 174.1 ms (median of 7) | - | - |

**The component adds nothing to start**, because it is loaded on first use and not at boot: the four
Lua seams pay per call, not per process. What a process pays is the *first* call: +3.0 ms when the
precompiled `.cwasm` exists, and ~172 ms when it does not (one compile of that component, then cached
in `<home>/.wasm-agent/cache/components`).

For the agent-core component the split is instrumented in the tree (`WA_CORE_TIMING=1`,
`wa --core-component <agent-core.wasm> <script>`):

| phase | cold | with the `.cwasm` cache |
| --- | --- | --- |
| load (compile, or deserialize from cache) | 312.3 ms (compiled) | 0.8 ms (cache) |
| instantiate | 0.13 ms | 0.12 ms |
| run a no-op script | 1.5 ms | 0.9 ms |

### 1.4 What a node does today when the component is missing, refuses, or traps

Measured, not read: a scratch home with **no** component directory, and then the `memory-crash` fixture
(`rust/components/memory-crash`, built here, 78,682 bytes) pointed at with
`WA_MEMORY_COMPONENT_WASM`.

| state | what the gate did | what the caller saw | what was logged |
| --- | --- | --- | --- |
| component not installed | fell back to the native path | the native answer, normally | one line, once per (op, reason): `memory: recall served natively: component_missing` |
| component refuses the request | fell back to native | the native answer | `memory: remember served natively: sql_policy_refused:sql_journal_payload_invalid` |
| component wedges (spins forever) | epoch deadline killed it, then fell back | the native answer | `memory: remember served natively: component_wedged:remember:error while executing at wasm backtrace:` |
| component answers `ok` with the wrong contents | **nothing** - the answer was used | **an empty result where the native path returns rows** | nothing |

The last row is the one that decides item 2. Reproduced here: two facts written into the store through
the crash fixture's fallbacks, then `recall`/`memories` with the fixture installed answered `hits 0` /
`0` while the same calls with the feature off on the same database answered `1` / `2`. The gate's own
rules (`lua/core/memory.lua`, `seam()`) check for a *missing*, *failed* or *empty* answer; an answer
that is well-formed and wrong passes all of them. Today the twin is what makes that survivable, because
the operator can turn the feature off. With no twin, a component that lies is the whole store.

The wedge row is also the answer to "does a cancel reach a running component": with
`WA_MEMORY_COMPONENT_TIMEOUT_MS=200` the spinning guest was killed in **203.2 ms of CPU** - the
deadline plus the engine's 10 ms epoch tick - and the call returned normally through the fallback.

## 2. What "the component fails" has to mean once there is no twin

Victor's rule: *always available*. A node whose component is missing must still boot, still answer, and
still say **which feature is off, by name** - not silently, and not with a stack trace instead of a chat.

The pieces of that answer already exist and can be kept as they are:

* **The resolver's word is the node's word.** `wa features` already prints `installed / enabled /
  active / reason` per feature and exits 3 when a feature the operator asked for is not there;
  `component_missing`, `component_pin_mismatch` and `component_unreadable` are the names
  (`rust/wa-features/src/lib.rs`). Nothing in this plan needs a second vocabulary.
* **A missing component is a state, not a crash.** Today the gate answers natively; with no twin the
  same state must answer `unavailable` *with the feature's name* and the rest of the turn must run. The
  place that must not change: the *start* cost of a node whose components are missing (14.0 ms measured
  above, no wasm touched) - the node must not try to load, and must not wait, to tell you it cannot.
* **A trap is a named off state, and it is not retried on the line.** One line per (operation, reason)
  is already the rule and it is the right one; with no twin the same line becomes the announcement that
  the feature is off, and the call returns a refusal the caller can act on instead of an empty value.
* **A lying component must not be able to be invisible.** The measured case in 1.4 is the gap: an answer
  that is well-formed and wrong is accepted. With a twin that is survivable; without one, the seam needs
  a cheap invariant per read (for memory: the store's own count or the ledger's journal row) before an
  empty answer is trusted - the shape `component_empty_answer` already uses, extended from "empty" to
  "empty where the store says otherwise".

**Which features can be off without losing the chat itself** - ranked by what a turn needs, not by what
is easy to remove:

| feature | off means | a chat still works? |
| --- | --- | --- |
| `hooks` | no configured hook runs; the shipped default guard still runs (it is evaluated in `M.fire` before the seam, in both paths) | **yes** - a session with no hooks is the default shape |
| `selfloop` | no wakes/notes/plan state machine; a turn still answers | **yes**, but unattended work stops (wakes are how a long mission continues) |
| `memory` | no facts stored or recalled; the transcript still works | **yes** for a single turn, **no** across turns - "remember this" is the whole point of the store |
| `codemode` | scripts run through the native path (today) / are refused (with no twin) | **yes** - a turn without code mode is a normal turn |
| `telemetry_sink` | no spans/samples shipped | **yes** - it is observability |
| `gateway` | model calls go where the native router sends them | **yes** |
| `mesh_component` | no peer calls | **yes** on one node, **no** on a fleet |
| `agent_core` | turns run in the binary's own Lua core | **yes** - that is where they run today |

So the two that must never be "off" in a fleet with no twin are `memory` (across turns) and
`agent_core` (the turn itself); the two that are cheapest to lose are `hooks` and `telemetry_sink`.

## 3. The removal order

Lowest risk first. "Removal" means: delete the native twin **and** the gate that chooses between them,
leaving the component as the only implementation, with the missing-component behaviour of item 2.

| # | feature | what the removal deletes | what proves nothing was lost |
| --- | --- | --- | --- |
| 1 | `hooks` | the native engine's entry list, command/lua hook runners and interpret step in `lua/core/hooks.lua` (the gate's `seam_or_native` branches); the file keeps the catalogue, the config reader and the shipped default guard | the existing parity suite: `scripts/test-hooks-component.lua` (component vs native answers on the same entries) plus `scripts/test-hooks.lua` / hook-event rows; the guard has its own row and must stay green with the component installed and with it missing |
| 2 | `telemetry_sink` | nothing on the call path (it is not wired): either wire it first or delete the component | there is no parity test because there is no second path - the honest move is to **not** call this a removal until one call path exists |
| 3 | `codemode` | the native script runner in `lua/core/codemode.lua` (the guest VM is `rust/components/codemode` + `quickjs`) | `scripts/test-codemode-component.lua` + `scripts/test-codemode-parity.lua` (already a never-dropped whole-tree row) |
| 4 | `selfloop` | the native state machine in `lua/core/selfloop.lua` (schedule/list/cancel/notes/plan/claim/settle) | the selfloop row plus the wake/jobs rows that drive it end to end |
| 5 | `mesh_component` | the native seam in `rust/wa-mesh/src/seam.rs` and `rust/wa-mesh-core`'s decision code | `scripts/test-mesh-component.lua`, `test-mesh-gate.lua`, `test-mesh-verb-admission.lua` |
| 6 | `memory` | the native SQL store in `lua/core/memory.lua` (the biggest twin: 1941 lines, every read and write of the ledger's memory tables) | `scripts/test-memory-component.lua` plus the memory rows of the fast path; and - item 2 - the new test for "a component that lies", which is the one this plan must add first |
| 7 | `agent_core` | the in-process Lua core as a *turn* path (`WA_AGENT_CORE_WASM` becomes the only way to run a turn) | the core-component parity rows in `scripts/test.sh` (native vs `--core-component`, which already compare outputs field for field) |
| 8 | `gateway` | nothing to remove yet: `rust/wa-model-gateway` is the only path | - |

The order is by *blast radius*, and it is not the same as "smallest first": `hooks` goes first because a
missing hook engine costs a guard that is still there and a session that behaves like a node with no
`hooks.json`; `memory` and `agent_core` go last because they are what a chat is made of, and because the
lying-component test does not exist yet.


## 6. The host: what has to stay native, and how thin it can get

Something native must load and run the components, so the host cannot be zero. The question is how
much of `rust/` it has to keep.

**Inventory, measured.** `rust/wa-capabilities/src/capabilities.rs` `REGISTRY` has **151**
capabilities (`grep -cE '^\s+(plain|upvalue)!\(' ...`); their entry functions are **1,887** lines,
found by parsing each entry's path and counting the brace-matched function body. Behind them
`rust/` outside `rust/components/` is **188,893 lines** of Rust (`find rust -name '*.rs'`, excluding
`components/`, `plugins/`, `ui-wasm/`).

**Checked against the current WASI list** (fetched 23/11 from `github.com/WebAssembly/WASI`,
`wasi-0.2` branch and `docs/Proposals.md`), not from memory:

| phase | interfaces |
| --- | --- |
| 3 - implementation (what 0.2 ships) | **Clocks, Random, Filesystem, Sockets, CLI, HTTP** |
| 2 - spec text | key-value store, wasi-nn, runtime config, WebGPU, I2C, messaging, HTTP informational response |
| 1 - proposal | **crypto, logging, SQL, SQL embed, threads, TLS, blob store, distributed lock service**, GPIO, observe, parallel, pattern match, SPI |
| 0.3 | 0.2's set with `future`/`stream` replacing explicit streams and polling - **no new device APIs** |
| **nothing at all** | **starting a process, a pty/terminal, signals, file locks, a keyring, systemd** |

The classification, by capability (the classes below are in the document's own vocabulary, and each
one names the interface that decides it):

| class | capabilities | entry lines | what is in it | verdict |
| --- | --- | --- | --- | --- |
| **(a)** could be a component today on standard WASI 0.2 | **62** | **725** | files and paths (14), clocks and random (3), environment/identity (7), `log` (wasi:cli/stderr), the 15 `graph_*` (calls to the graph component), the 7 seam calls (`memory`, `selfloop`, `hooks`, `mesh`, `codemode`, `components`, `component_mcp`), sockets (`relay`, `mesh_call`, `binding_*`, `beat`), `http`/`http_stream`/`http_sse`, `sha256` | moves into the guest, on `wasi:filesystem`, `wasi:clocks`, `wasi:random`, `wasi:cli`, `wasi:sockets`, `wasi:http`, plus direct WIT imports of the other components |
| **(b)** needs a small native import - WASI has no standard for it | **79** | **964** | starting processes (11: `exec`, `exec_timeout`, `operation`, `jobs`, `enqueue_completion`, `subagent`, `service`, `invoke`, `cli_reexec`, `quickjs`, `plugins`), the terminal/TUI (33 `Device` capabilities: `terminal_*`, `input_*`, `transcript_*`, `editor_*`, `opening_*`, `panel`, `ticker`, `client`, `audio`, `isatty`), `sleep` (0.2 has no sleep), `sign`/`verify` (keys), `system_resources`/`disk` (statvfs, CPU), `run_cancelled`, `telemetry`, `process_identity`, and the credential-bearing connectors (STT 5, fabric 4, WhatsApp 12, email 5) | a native import per family: `wa:host/process`, `wa:host/terminal`, `wa:host/keys`, `wa:host/system`, `wa:host/secrets` |
| **(c)** must stay native for speed or safety | **8** | **169** | the ledger: `sql_exec`, `sql_query`, `sql_rows`, `sql_patience`, `db_ready`, `mark_db_ready`, `state`, `resource` | stays native, with the measurement: a memory operation through a component costs **0.62-0.71 ms** against **0.06-0.08 ms** on the native path (§1.2), and the store is one SQLite file shared by every process - `wasi:sql` is a phase-1 proposal and `wasi:filesystem` gives no `flock` |
| unclassified in this pass | 2 | 29 | `plugins`, `binary_changed` | `plugins` is (b) (a native plugin registry), `binary_changed` is (a) |

**The number that answers the question.** If every (a) moves, these native modules go with it:

| module | lines |
| --- | --- |
| `rust/wa-graph` (the graph engine the `graph` component drives) | 5,668 |
| `wa-capabilities/src/graph.rs` + `graph_tests.rs` (the capability layer over it) | 2,920 |
| `wa-kernel-runtime/src/{memory,hooks,selfloop,mesh}_host.rs` (the proxies that exist only because the Lua core calls a component through the host) | 2,643 |
| `wa-capabilities/src/codemode_seam.rs` | 906 |
| `wa-capabilities/src/http_transport.rs` (the `http*` capabilities) | 405 |
| the connectors' native halves that duplicate the shipped `wa-email` / `wa-whatsapp` components: `wa-email-index` 1,217 + `wa-email-outbox` 902 + `wa-whatsapp-index` 2,167 + `wa-whatsapp-archive` 1,675 + `wa-whatsapp-outbox` 950 | 6,911 |
| **total** | **19,453** |

**So: ~19,500 of 188,893 lines (10%) move, and ~169,400 lines of native Rust remain.** That is the
honest answer, and it is the opposite of the intuition in the question: going WASI-default does **not**
make the host thin, because the (a) capabilities are the small part. What stays is the terminal
(`wa-term` 11,068 + `wa-window` 3,208), the node supervisor (`wa-sentinel` 16,170), the serving layer
(`wa-capabilities/serve.rs` 4,848), process start and subagents (`operations.rs` 3,278 +
`subagents.rs` 2,309), the mesh (`wa-mesh` 11,246 + `wa-mesh-core` 2,558), telemetry (8,173), the
kernel runtime that *is* the components' host (`wa-kernel-runtime` 20,111), keys and vault
(`wa-keystore` 1,479 + `wa-vault` 2,372), TLS (`wa-tls` 1,167, a phase-1 proposal), and the ledger.

**The interface the thin host implements per platform** - this is also exactly the porting cost of
item 5:

```wit
package wa:host@0.1.0;

// What every platform must provide before a component can run. Everything a guest gets from WASI
// 0.2 stays a WASI import; these are the families WASI has no standard for today.
interface process { ... }   // spawn, stdout/stderr, exit status, signals, a terminal in pty mode
interface terminal { ... }  // raw mode, size, key events, the screen the TUI draws on
interface keys { ... }      // open a keyring item, sign, verify - never the key's bytes
interface system { ... }    // statvfs, cpu/memory, locks, sleep, systemd notify
interface secrets { ... }   // a connector's credential, granted by name
interface ledger { ... }    // the one SQLite connection (class (c))
```

One world composed of `wasi:cli|filesystem|clocks|random|sockets|http@0.2.0` imports plus these six
interfaces is the whole porting surface: a new platform implements the six and gets every component
unchanged. Today the same surface is spread across 151 host functions with no file that lists them for
a porter - `REGISTRY` is a Rust table, and `docs/HOST.md` is its prose.
