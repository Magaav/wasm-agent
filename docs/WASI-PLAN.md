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

## 7. Runtime optimizations, each measured before it is proposed

The brief's greps first, re-checked on this tree (23/11, `1cc642f8`): precompiled `.cwasm` caches are in
`components.rs:195` (`disk_cached`), `core_component.rs:929` (`load_component`), `quickjs.rs`,
`wa-kernel-runtime`; epoch interruption in 13 files (`grep -rl epoch_interruption`); a pooling
allocator in 3 (`components.rs` `pooled_engine`, `core_pool`, `wa-core-pool-bench`); wasmtime **50.0.1**
(`rust/Cargo.lock`). `InstancePre`/`instantiate_pre` is still absent (0 files) while `Linker::new` is
built per call at `core_component.rs:1101,1502`, `memory_host.rs:412`, `hooks_host.rs:194`,
`selfloop_host.rs:350`, `mesh_host.rs:239`, `codemode_seam.rs:650`.

**What one call costs, split.** Two independent measurements agree, and the second one is the prior
mission's own phase instrumentation (`docs/missions/reports/component-calls-cheap.md`, branch
`change/component-calls-cheap`, 23/11, same laptop, `WA_PHASE_PROFILE` patch since reverted):

| phase | codemode `open` (prior, n=40) | memory seam, refused op (here, n=50) |
| --- | --- | --- |
| artifact read + sha256 | 261 us (median) | ~150 us (read 52 + SHA-256 99, measured on the same 207,332 B file) |
| `WasiCtx` + `Store` + `Linker::new` + 2x `add_to_linker` | 216 us | - |
| `Component::instantiate` | 186 us | - |
| the two together, as one floor | 663 us | **204 us** (p50), 223 (p95) |
| the guest's own work | 20,808 us (95 %: booting QuickJS) | 0.5-0.7 ms for a real memory op |

The difference between 663 us and 204 us is the component (codemode carries more imports and is bigger)
and the op (codemode's `open` builds a QuickJS runtime; the memory floor returns an error at once). Both
point the same way, which is the verdict:

| what | measured saving | verdict |
| --- | --- | --- |
| **(a) link once, instantiate from an `InstancePre`** | link+store is **216 us** and instantiate **186 us** per call; of a real memory call (620-714 us) that is 25-35 %, of a codemode call (21 ms) 2 %, of a turn (5.7 s) **0.1 %** | **worth it only together with (a')**: the 261 us read+sha256 happens on *every* call and repeats a fact the resolver already verified (`load_in` re-reads and re-hashes the artifact; the in-process `compiled` cache then finds the compiled component). Caching the `Installed` struct per component (invalidated on pin change) plus an `InstancePre` removes **~0.45 ms of the 0.66 ms setup** - and the same sha256 shows up as **20 % of an idle node's busy CPU** in the prior report's symbol samples |
| **(b) a warm instance per component** | saves the same ~0.4 ms of setup per call, but the state is per call by construction: memory opens a scoped SQL session and a transaction, codemode opens a script, hooks carries a per-decide payload. Only `selfloop`/`memory` *reads* could reuse a store between calls | **not worth it now** (0.1 % of a turn); revisit if the call count per turn grows |
| **(c) load a component on first use, not at start** | **already true**: `wa` with a script starts in **14.0 ms** and the first memory call adds **+3.0 ms** with the `.cwasm` cache, **+172 ms** without (one compile, then cached). `wa features` starts with no component loaded (prior report: 0.007 s CPU, RSS 16 MB) | **done**; the only open item is the cold-compile burst (6.13 s for the largest component, prior report) - a cache-priming question, not a start-cost one |
| **(d) pass large bodies as handles/streams** | the payload is real: **1,125 capability calls and 4.8 MB back per context build**, `read_file` alone **760 calls / 10.5 MB** per turn (prior report, `bench-core-calls`); Lua decodes JSON at ~17.8 MB/s, so **~24 ms of a 117 ms context build is JSON** | **the biggest single win on this list**, and it is not a WASI question: it is "do not copy 10 MB through a string". A handle (open the file, read it in the guest) or a stream removes most of it |
| **(e) Esc inside a component through the epoch deadline** | the deadline **does** interrupt a running component: a wedging guest with a 200 ms deadline was killed in **203.2 ms of CPU** (section 1.4). Esc itself is **cooperative**: the guest polls `host.run_cancelled` (`lua/core/agent.lua`, `codemode.lua`), so a component that does not poll (a long query, a wedge) runs to its deadline | **partly there**: the mechanism exists (epoch + 10 ms tick), the wiring from Esc to the store's deadline does not; the cost of missing it is up to the deadline (memory's table runs 50-1,000 ms per op) |

So the answer to *"which optimizations would be worth adding?"* is: **(d)** (sizes, measured), then
**(a')** (stop re-reading and re-hashing the artifact per call), then **(e)** (wire Esc to the deadline),
and **not** (b) or (c).

## 8. Upstream asks (report only - Fable and Victor post, the worker never does)

Each row: what wa needs, what it costs wa **measured here**, a reproduction with nothing private in it,
and the issue that already exists (checked 23/11 through the GitHub search API, so the numbers are live,
not remembered).

### 8.1 Starting a process (bash, cargo, a subagent)

- **Cost to wa**: the whole (b) process family - 11 capabilities (`exec`, `exec_timeout`, `operation`,
  `jobs`, `enqueue_completion`, `subagent`, `service`, `invoke`, `cli_reexec`, `quickjs`, `plugins`),
  and behind them `wa-capabilities/src/operations.rs` (3,278 lines) + `subagents.rs` (2,309). A component
  cannot run a hook command, a subagent or `bash` at all, so the whole agent-core component still has
  to ask the host for every process it starts: that is why `wa:kernel` exists and why `WA_AGENT_CORE_WASM`
  is a switch and not the only path.
- **Existing**: WebAssembly/WASI **#414** (*posix_spawn/CreateProcess API*, open), **#763** (*Provide
  interface to spawn a new wasm component*, open), **#899** (*wasi:exec*, open). Nothing in the phase
  list (`docs/Proposals.md`) proposes a process interface at any phase.
- **Reproduction** (20 lines, no wa code): a component that imports a process interface has no world to
  compile against; the smallest honest statement of the gap is the WIT nobody can import:

```wit
package example:spawn@0.1.0;

interface process {
  enum signal { term, kill, int }
  record status { code: s32, signal: option<signal> }
  spawn: func(program: string, args: list<string>, env: list<tuple<string,string>>) -> result<u32, string>;
  wait: func(handle: u32) -> result<status, string>;
  kill: func(handle: u32, sig: signal) -> result<(), string>;
}
world w { import process; }
```

  Against `wasmtime 50.0.1` and `wasi:cli@0.2.0` this compiles to nothing: there is no such interface
  to link, and the only way to start a program is a host function of wa's own (`wa:kernel/host.call`).

### 8.2 A terminal / pty interface (raw mode, size, key events)

- **Cost to wa**: 33 `Device` capabilities - the TUI's whole surface - and behind them `wa-term`
  (11,068 lines) + `wa-window` (3,208) + `wa-capabilities/src/audio.rs` (592) + `client_bridge.rs`
  (619). Measured shape of that surface: an idle TUI node burns 7.6 % of a core and the *drawing* is not
  in its busy samples (`docs/missions/reports/component-calls-cheap.md`).
- **Existing**: no interface; the two closest conversations are closed (WASI **#42**, *Does the current
  spec allow for things like `ioctl` and `termios`?*). `wasi:cli` has `stdin/stdout/stderr` as byte
  streams and nothing about a terminal's mode, size, or key events.
- **Reproduction**: a component that wants raw mode and a key event cannot express it: `wasi:cli/stdin`
  reads, and there is no `isatty`, no `termios`, no size, no resize event. 20 lines of WIT (an `interface
  terminal { set_raw: func(on: bool); size: func() -> tuple<u16,u16>; read_key: func() -> ... }`) have no
  home in `wasi-0.2`; wa carries all of it in `wa:kernel/host.call` today.

### 8.3 Path-independent component builds (cargo)

- **Cost to wa, measured** (`components.lock`, re-measured 13/11): two builds in one path gave
  **8,582,128 bytes / `f3d60624…` twice**; the same tree copied to another path gave **8,582,132 bytes /
  `cb410807…`**. Cause measured: a path package's `-C metadata` is a hash of its canonical absolute path
  (`libwa_whatsapp_index-49271f4b…` in one tree, `-5caf7479…` in the other). Consequence: a pin names
  ONE build from ONE path, so "build it where you are and publish" is not possible, and every
  per-component publish (item 4b) has to happen in the canonical checkout.
- **Existing**: rust-lang/cargo **#13586** (*Not reproducible when a project is copied to another
  directory*, closed), **#8140** (*Non-reproducible `-C metadata=hash` passed to rustc depending on the
  compiling OS*, open), **#17512** (*build-dir artifact duplication*, open for the neighbouring need).
- **Reproduction**: `cp -a repo repo2 && (cd repo && cargo build --release) && (cd repo2 && cargo build
  --release) && sha256sum repo/target/release/lib*.so repo2/target/release/lib*.so` - two digests for
  identical sources, and the difference is `-C metadata` alone.

### 8.4 File locking (`flock`)

- **Cost to wa**: the ledger is one SQLite file shared by every process of a node; `sql_patience`
  exists only to bound how long a statement waits for the lock, and the memory seam's own deadline table
  (50-1,000 ms per op) is sized around it. A component cannot take that lock itself, which is one of the
  two reasons the ledger stays native (class (c), section 6).
- **Existing**: WebAssembly/WASI **#773** (*File locking*, open).
- **Reproduction**: a component opening the same file twice and writing between the opens has no
  advisory lock to take; `wasi:filesystem` has no `flock`/`fcntl` and no `O_EXCL` answer that survives a
  crash in the middle of a two-file update.

### 8.5 Sleeping in a component

- **Cost to wa**: one capability (`sleep`, 8 lines) and the engine's epoch tick (10 ms) is the only other
  way to wait; every "wake in 30 s" today is a host call.
- **Existing**: WebAssembly/WASI **#691** (*Split interfaces to separate sleeping from reporting the
  time?*, open), **#857** (*clocks: Cannot implement `clock_nanosleep(CLOCK_REALTIME, ...)` in C*, open).
- **Reproduction**: `wasi:clocks/monotonic-clock@0.2.0` has `now` and `resolution` and no `sleep`; the
  only portable way to wait in a component is to spin (and burn a core the host pays for).

### 8.6 TLS and credentials for a component's own HTTP

- **Cost to wa**: `wa-tls` (1,167 lines) stays native, and no component can do its own HTTPS: the
  model-gateway component imports `wa:kernel/http@0.2.0` (the tree's own interface,
  `rust/components/model-gateway/wit/model.wit:325`) instead of `wasi:http`, because credentials and the
  policy that decides who may call what live in the host. `wasmtime-wasi-http` is not even a dependency
  of this tree.
- **Existing**: `wasi:tls` is a **phase-1** proposal (`docs/Proposals.md`), `wasi:crypto` likewise;
  `wasi:http` is phase 3 and has no notion of a credential or a policy.
- **Reproduction**: a component that imports `wasi:http/outgoing-handler@0.2.0` and requests
  `https://example.com` gets whatever the *embedder* does about TLS; there is no standard import that
  lets the component own it, and no standard for "this component may use this secret".

### 8.7 What is *not* an upstream ask

Two items from the brief's expectation list are answered by the measurements and need no upstream
request: **"link once" (item 7a)** is a wasmtime API that already exists (`InstancePre`), so it is wa's own
call path that has to use it; and **"the component model can't share an instance"** is not wa's problem -
the prior report measured one instance per call and found setup is 0.1-0.8 % of a turn
(`component-calls-cheap.md`).

## 4. Factory speed, measured

### 4a. Which rows one component owns, and what that subset costs

The full fast path on this laptop today: **999 s, 144 checks** (a run at 17:21 from another worktree of
this repository - `/tmp/fast-ok.log`, `fast: kept 1 failed row log(s) ... fast path FAILED (7 of 144
checks, 0 skipped, 999s)` - quoted because the suite rule for this wave forbids running the whole thing).

The material it has to choose from: **418** `scripts/test-*.lua`, of which **74** are excluded from the
fast path (`scripts/fast-path.exclude`), so **360** are candidates; plus **29 rows the runner may never
drop** (`wa_fast_core_rows` in `scripts/lib/fast-rows.sh`: the row-environment probe, the ten
`test-land-*` parts, the five `test-land-quick-*` parts, `test-event-ledger`, `test-land-health-program`,
`test-release-channel-e2e`, `test-refusal-contract`, `test-tool-schema-fidelity`,
`test-codemode-parity`, `test-email-connector`, `test-whatsapp-send`, `test-wit-deps`,
`test-tool-args-parity`, `test-edit-aliases`, `test-product-version`, `test-land-gate-rows`, ... - the
list is 29 lines long and printed by `source scripts/lib/fast-rows.sh; wa_fast_core_rows`).

Which of the 360 a change selects is the planner's rule (`lua/core/land.lua:1459-1501`): a row is affected
when the round changed it, when its *name* names a changed module (`lua/core/agent.lua` ->
`scripts/test-agent*.lua`), or when the row's **text mentions the changed path**. Applied to the
component directories here (`grep -rlF <path> scripts/test-*.lua`):

| change | rows that name it |
| --- | --- |
| `rust/components/memory/**` | `test-memory-component.lua` (1) |
| `rust/components/hooks/**` | none (0) |
| `rust/components/selfloop/**` | none (0) |
| `rust/components/codemode/**` | none (0) |
| `rust/wa-mesh/**` | `test-mesh-component.lua`, `test-mesh-gate.lua`, `test-mesh-verb-admission.lua` (3) |
| `wit/memory/**` (the seam's own contract) | `test-wit-deps.lua` (1, always-on anyway) |

The honest reading: **a change inside a component owns one row, and pays for 29 rows it does not own**
plus the runner's contract checks (prompt docs, instructions, landing queue, landing baseline, fast
binary/environment/result, install front door, component provisioning, `wit-lint`, `wit-deps`). That is
the *floor* of every narrowed run, and it is why "build and test only what changed" does not get cheaper
than ~30 rows.

Measured costs around that subset: rebuilding the `memory` component after one changed file **1.4 s**;
rebuilding `wa` after one changed file in `wa-kernel-runtime` **0.3-1.1 s**; `publish-components.sh --check`
**0.55 s** (it refuses with `commit_not_on_pushed_branch`, correctly).

**What the component's own rows cost, measured singly** (the suite rule allows a single test file; the
same scratch home, the components the fast run had just built from this tree):

| row | wall | verdict |
| --- | --- | --- |
| \`scripts/test-memory-component.lua\` (12 checks + 24 native/component parity comparisons) | **628 ms** | green; it also prints its own per-op comparison - \`search_messages\` native 0.2 ms vs component 1.8 ms, \`sessions\` 0.3 vs 1.8 |
| \`scripts/test-wit-deps.lua\` (16 checks over 34 vendored copies of 11 canonical files) | **36 ms** | green |

So the part of a component change that is *the component's own* costs **0.66 s**. Everything else a
component round pays is the floor: the 29 never-dropped rows (the land parts are "under 11 s alone"
each, by their own header comment) plus the runner's contract checks.

**And the measured factory limit is the lock, not the work.** The narrowed run of those two rows
(\`flock -o ~/Work/missions/.suite.lock env WA_FAST_ROWS="scripts/test-memory-component.lua
scripts/test-wit-deps.lua" bash scripts/fast.sh\`) spent **913 s wall** and never reached a row: three
other missions' runs and two installs held the lock, and the runner had only built this tree's binary and
its components when the window closed (it exited 2 with no row executed - an invocation fact, not a
verdict). One heavy suite at a time on 16 cores, each up to 999 s: that queue is the real cost of a round,
and no amount of component splitting removes it.

### 4b. What hot-swapping ONE component on a running node needs beyond `wa dev`

`wa dev <component-dir>` (`rust/wa-host/src/dev.rs`) is a loop for **service** components: watch, `cargo
build --target wasm32-wasip2`, lay the artifact down in a dev directory, then `wa_kernel_runtime::dev::swap`
- start the new instance beside the old one, wait for `lifecycle.report(ready)`, stop the old one; a
candidate that exits or never reports health keeps the previous instance. It deliberately does not join a
running `wa serve` registry (there is no node endpoint for "start a second instance of this name and keep
the old one").

For the components that are on a **per-call** path (memory, hooks, selfloop, codemode, mesh) a swap needs
nothing else on the call side, and that is measured: every dispatch re-reads the artifact and its pin
(`load_in`, `components.rs`), so the next call after the swap uses the new bytes and an in-flight call
keeps the copy it already loaded. The price of that property is the per-call read + SHA-256 in section 7.

What does need building, outside `wa dev`:

| need | today | what a per-component swap adds |
| --- | --- | --- |
| publish | `scripts/publish-components.sh` builds, verifies and bundles **every** component `components.lock` pins, one release tag `components-<sha12 of the lock>`, and refuses a commit that is not on a pushed branch | a per-artifact tag/pin: one changed component today republishes the whole bundle and re-pins the whole lock |
| pin | `components.lock`, edited by hand, judged by `scripts/test-component-pins.sh` | a generated pin file: there is **no** `component-pins-generated` in this tree (`rg` finds 0 files) - the brief's name for it does not exist yet |
| signature | the pin is a sha256 in a committed lock; the *release* signature covers release sums (`scripts/sign-release.sh`, `scripts/lib/release-signing.sh`) | a signature over the per-component bytes, so a swapped artifact is trusted for the same reason a release is |
| in-flight calls | nothing needed (per-call load, above) | nothing |
| a node's own cache | `~/.wasm-agent/cache/components/<sha>-<engine>.cwasm`, keyed by pin | nothing: a new pin is a new key |

### 4c. How much of a week's change lives inside the one agent-core component

`git log --since='14 days ago' --oneline -- <path>`, this repository, 23/11:

| window | commits | `lua/` | `rust/` | `wit/` | `components.lock` | `scripts/` | `rust/components/` |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 14 days | **1,972** | 765 (39 %) | 384 (19 %) | 4 | 22 | 1,163 | **48 (2.4 %)** |
| 7 days | **1,528** | 561 (37 %) | 279 | 2 | - | - | **12** |

Per component over the same 14 days: `codemode` 16, `graph` 2, `model-gateway` 1, `telemetry-sink` 1, and
`agent-core`, `hooks`, `memory`, `mesh`, `selfloop` **0**.

So today's split gives "build and test only what changed" a payoff on **2.4 % of the work**, and the other
~97 % is one unit: the Lua core plus the binary it runs in. The Lua that would live *inside* agent-core is
**37-39 % of every commit** - that is the mass a finer split along the WIT seams would have to carve up
before per-component builds pay for the factory's real cost (the 999 s suite). The static library and the
`wa` incremental rebuild are already fast (1.4 s and 0.3-1.1 s); the tests are not, and they are not
time-sliced by component today.

## 5. Omni device: which hosts exist, and what a third would need

**Hosts that ship today** (`releases/index-linux.json`, `releases/index.json`):

| host | target | channel |
| --- | --- | --- |
| Linux x86_64 | `x86_64-unknown-linux-musl` | `index-linux.json`, `wa update` |
| Linux arm64 | `aarch64-unknown-linux-musl` | `index-linux.json` |
| Android arm64 (Termux) | `aarch64-linux-android` | `index.json`, prebuilt only (`scripts/release-android.sh`: *"the phone cannot compile this workspace (measured rustc SIGSEGV on cranelift), so the release, not a build, is its update channel"*) |
| Windows | 28 `.rs` files carry `cfg(windows)` code and `AGENTS.windows.md` describes the shell, but **no Windows artifact is in either release index** | none |

**The components do not have to be ported.** A component is wasm32-wasip2 and the same bytes run on every
host (`components.lock`: *"its bytes are wasm32-wasip2, so they do not depend on the CPU - the same artifact
runs on arm64 and x86_64"*). What a third host ports is the **six interfaces of section 6** plus WASI's

own six. Per capability family, what each candidate host would have to provide:

| family (section 6) | macOS | Android/Termux | browser (a JS host) |
| --- | --- | --- | --- |
| WASI 0.2 itself (files, clocks, random, sockets, cli) | provided by wasmtime-wasi on macOS, complete | complete, but the app sandbox restricts files to Termux's own home - the ledger and the component dir already live there | **files and sockets have no complete story**: OPFS gives no durable random writes and no sockets beyond fetch/WebSocket; clocks/random are fine |
| \(a\) the 62 guest-side capabilities | nothing to port - they move into the guest | same | same |
| process (\(b\): exec, subagents, `bash`) | `posix_spawn` + `waitpid`, ~ the same shape as Linux | Termux has fork/exec for its own binaries; `systemd` does not exist, so the supervisor model changes | **not possible**: a page cannot start a process |
| terminal/pty (\(b\): the TUI, 33 capabilities) | `termios` + `ioctl(TIOCGWINSZ)`, ~ the same shape | `termios` works in Termux | a terminal can be *drawn* in a page, but there is no pty and no raw keystroke stream outside the page |
| keys (\(b\): sign/verify, keyring) | Security.framework's keychain | no keychain in Termux: needs Android Keystore through a JNI shim, or a file with a passphrase | WebCrypto + IndexedDB (non-extractable keys) - the closest of the three |
| system (\(b\): statvfs, CPU, locks, sleep, systemd) | `statfs`, `sysctl`, `flock` | `statvfs`/`flock` present, no systemd | **not possible**: no statvfs, no flock, no sleep beyond timers |
| ledger (\(c\): SQLite) | `sqlite3` links as it does on Linux | same | SQLite compiled to wasm over OPFS: real, but every write is a copy and two tabs cannot share one store |

So the omni-device answer is: **the component half is already portable (one artifact, three hosts), and
the host half is six interfaces**. macOS and Termux are each a small port of (process, terminal, system)
plus a real one for (keys); a browser host can run the guest only if the *chat* does not need a process,
a terminal or a shared ledger - which today it does.

## Decisions

*Empty by design.* Fable reads this page, decides, and each decision is appended here with its reason.
Part 2 (removing the native twin of ONE feature) waits for that go.

## Every item of the brief, and where it is answered

| item | where | measured? |
| --- | --- | --- |
| 1. lines, calls per day, cost per call, start cost, missing/trap behaviour, per feature | sections 1.1-1.4 | lines and costs measured here; **calls per day per path is not measured**: the node's ledger (`~/.wasm-agent/memory.db`) is refused by the secret guard (`secret_path_denied`) and the fleet is out of bounds for this mission (rule 13). What is measurable was measured: `wa features` says 8/8 `component`, and this node's retained logs (`~/.wasm-agent/logs/cli-stderr.log`, 19 KB) contain **zero** `served natively` lines |
| 2. what "the component fails" means with no twin, and which features can be off | section 2 | the four states (missing, refusing, wedged, lying) were produced and observed; the ranking is reasoning on top of that |
| 3. the removal order | section 3 | order and tests named per feature |
| 4a. rows per component, and the subset's cost | section 4a | rows counted by `grep -rlF` over `scripts/test-*.lua`; full path 999 s; subset row content measured, wall time blocked by the shared suite lock (see there) |
| 4b. what a one-component hot swap needs beyond `wa dev` | section 4b | `wa dev`'s own header, `publish-components.sh --check` run (0.55 s, refused `commit_not_on_pushed_branch`), `rg` for a pins-generated file (0) |
| 4c. how much of a week is Lua inside agent-core | section 4c | `git log --since` counts |
| 5. omni device | section 5 | targets from the two release indexes; per-family analysis |
| 6. the host | section 6 | 151 capabilities, 1,887 entry lines, 188,893 native lines, WASI phase list fetched 23/11 |
| 7. runtime optimizations | section 7 | every row has a number; two are answered "do not build" |
| 8. upstream asks | section 8 | six asks, each with its measured cost, a reproduction and a live issue number |

## How to re-measure any row

Everything here is one of five commands. All of them are hermetic: a scratch `WASM_AGENT_HOME`, a
`HOME` of their own, `WASM_AGENT_RENDEZVOUS=`/`WASM_AGENT_RELAY=`/`WASM_AGENT_MANAGED=0`, and components
copied out of the node's install (never the live home).

1. **Per-call, both ways**: a Lua script that calls one module's public function `N` times under
   `os.clock`, run twice with `WA_<FEATURE>_COMPONENT=1` and `=0`. (The shape used here is in the mission
   report, `docs/missions/reports/wasi-only-plan.md`.)
2. **The floor of a crossing**: the same script calling `host.<seam>('{"op":"wb_no_such_op"}')`, which the
   guest refuses after instantiate.
3. **Start cost**: `python3 -c` around `subprocess.run("wa --db ...", env=...)` with `WA_SCRIPT` a no-op,
   once with the cache, once with `~/.wasm-agent/cache/components` removed, once with `WA_COMPONENT_CACHE=0`.
4. **agent-core's own split**: `WA_CORE_TIMING=1 wa --core-component <agent-core.wasm> <script.lua>`,
   cold and warm.
5. **A wedge, and the deadline**: `WA_MEMORY_COMPONENT=1 WA_MEMORY_COMPONENT_WASM=<memory-crash.wasm>
   WA_MEMORY_COMPONENT_TIMEOUT_MS=200`, then `M.remember('wedge: ...')` - the call returns after
   **203.2 ms** of CPU with `component_wedged` in the log and the native path answering.

## What this page does not claim

- It does not claim a fleet-wide call count per path (item 1): the ledger is refused to an agent tool by
  the secret guard, and this mission may not call a live peer. The local evidence is in section 1 and in
the checklist above.
- It does not claim a wall time for the narrowed fast-path run: the run was queued behind the shared suite
  lock (three other missions' runs and two installs) for its whole window here, and the queue itself is the
  finding of section 4a.
- It does not claim any line count as a parse: component "test-ish" lines are a bound (from the last
  `#[cfg(test)]` to EOF, plus `tests*.rs`), and the capability line counts are entry functions, not their
  transitive callees.
- Nothing was installed, nothing was pushed, no peer was contacted, and `Part 2` has not started.
