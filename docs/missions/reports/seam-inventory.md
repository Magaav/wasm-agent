# seam-inventory - every boundary between parts of wa that is not WIT yet (Victor 27/11)

Tree: this branch, cut from `origin/main` `04b7a38b`. The law: `ARCHITECTURE.md` **"Seams are WIT, and async by default"** - "a
boundary between parts of wa (host <-> component, component <-> component, a node <-> the fabric API) is defined in `wit/`.
Work that takes time returns a `future`; output that keeps coming is a `stream`; dropping either cancels interest. Nothing
new exposes a status to poll." The shared wait is one place: `lua/core/codemode_pending.lua:54-55` - `DEFAULT_WAIT_S = 60`,
`MAX_WAIT_S = 300`, then a pending handle.

**What is WIT today** (`wit/`, 27 `.wit` files, worlds): agent-control, bus, codemode, fabric, hooks, kernel,
kernel-v2, memory, mesh, model (+ router), queue (`producer-consumer`, `worker-consumer`, `admin-consumer`, `consumer`,
`queue-provider`), seams (`stt-provider`, `ocr-provider`, `tool-component`), selfloop, telemetry, vault.

**The pattern this inventory is about:** a `host.*` capability that is really a request to a *component*, sent as a job
on the durable queue (`wit/queue`'s `producer-consumer`) and then **waited for in the host** with a private constant
(2 s), falling back to a job id when the wait expires. It is not a WIT seam (the host is not a component, and the
question never becomes a `future`), and the wait is a number nobody shares.

## The inventory

| # | surface | file:line | what crosses | sync/async | private wait | callers | measured cost (cited) | verdict |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | `host.whatsapp_search` / `whatsapp_read` / `whatsapp_reactions` / `whatsapp_media` / `whatsapp_download` / `whatsapp_backfill` | `rust/wa-capabilities/src/whatsapp_query.rs:3-7` (the crossing), `:45` (`DOWNLOAD_WAIT_MS = 10_000`), `:168` (the ask) | a question is a **job on the shared durable queue** to the `wa-whatsapp` component, then the host waits | sync, with a poll fallback (a job id is returned when the wait expires, `rust/wa-whatsapp-index/src/lib.rs:700`) | **2 000 ms** (`rust/wa-whatsapp-index/src/lib.rs:75 WAIT_MS`), **10 000 ms** for a download (`whatsapp_query.rs:45`) | 6 host capabilities, reached from Lua by `whatsapp_search`, `whatsapp_read`, `whatsapp_reactions`, `whatsapp_media`, `whatsapp_download`, `whatsapp_backfill` (plus `whatsapp_contacts`, `whatsapp_message`, `whatsapp_native` around the same index) | whatsapp_query is 3 218 lines with 15 commits in 30 days (`_orch/move-list.md` item 9); the wait itself is 2 s, and past it the caller is handed a job id to poll - the law's "nothing exposes a status to poll" | **MOVE** - brief queued: `whatsapp-read-waits-on-a-future.md` (priority 1: a slow read today reaches the model as a job id) |
| 2 | `host.email_query` (the mail index) | `rust/wa-capabilities/src/email_query.rs:3` (says it follows the WhatsApp architecture) | the same queue job into `wa-email-index` | sync, with the same poll fallback | **2 000 ms** (`rust/wa-email-index/src/lib.rs:47 WAIT_MS`) | Lua `email_query` and the mail canary (`lua/core/canaries/mail.lua`) | `wa-email-index` 2 119 lines (`_orch/move-list.md` item 2) | **MOVE** - brief queued: `email-read-waits-on-a-future.md` (priority 2) |
| 3 | `host.stt_*` (the speech queue's node half) | `rust/wa-capabilities/src/stt.rs:1` ("the node half of queue phase 2 for speech"), `rust/wa-capabilities/src/whatsapp_send.rs:485` (`wa.stt` enqueued with `fresh_for(60_000)`) | a transcription request is a queue job into `wa-stt-remote`; the *provider* direction already has a WIT world (`wit/seams/seams.wit:67 world stt-provider`) | sync enqueue (the enqueue itself is fine) + a per-job freshness constant | `fresh_for(60_000)` inline at `whatsapp_send.rs:485` (a literal, not a named constant) | Lua `stt_submit`, `stt_pending`, `stt_answer`, `stt_tick`, `stt_worker`, `stt_admin` | `wa-stt-remote` has **no** WIT world of its own (move-list item 6: "Gap = no world for: terminal, OS process, whatsapp, email, stt, audio, plugins/client") | **MOVE (partial)** - the request/answer half should be the seam, the enqueue stays; brief queued: `stt-question-returns-a-future.md` (priority 2) |
| 4 | `host.whatsapp_send`, `host.email_send` | `rust/wa-capabilities/src/whatsapp_send.rs:474`, `rust/wa-capabilities/src/email_send.rs:126` | an outbox job (`outbox::QUEUE`, `fresh_for(outbox::FRESH_MS)`, `max_attempts`) | async by nature: the caller gets an id and never waits | none on the caller's side (`FRESH_MS` is the job's own lifetime) | Lua `whatsapp_send`, `email_send` | the same `move-list` rows as 1-2 | **KEEP** - a send is a durable job and its id is the answer; nothing waits, so the async law has nothing to fix here. The constant's lifetime is a queue policy, not a seam |
| 5 | code graph (`host.graph_*`) | `rust/wa-capabilities/src/graph.rs:1` ("served by the `graph` WASI component"), `:37` (the measured crossing) | the host -> `rust/components/graph` through the kernel's `service-component` world (`wit/kernel/kernel.wit:151`); the component keeps its own store | sync calls into a component | none named; the cost is the call itself | every `host.graph_*` caller (Lua `graph_*`, the indexer) | **~51 s in-process vs ~578 s through the component** (measured 05/11, quoted at `graph.rs:37`) | **ALREADY WIT** - the boundary is a WIT world today; the row that should exist is a *cost* row (578 s), and `graph-dormant.md` / `graph-index-tear-cause.md` / `graph-one-store-per-root.md` already sit in the queue for that surface |
| 6 | terminal and operations (`wa-term`, `wa-operation`) | `rust/wa-term/src/lib.rs:1`, `rust/wa-operation/src/lib.rs:1` | console state and operation supervision, reached from the host as **crates in-process** (no world, no component) | sync in-process calls | n/a (in-process) | the chat/CLI surface, the tool runner | 14 154 lines (terminal) and 8 772 (operations), 95 and 57 commits in 30 days (`_orch/move-list.md` item 4) - the two biggest single levers, and neither has a WIT world | **MOVE to WIT** (they are the `move-list`'s own top levers; the world gap is item 6 of that file) - brief queued: `terminal-and-operations-need-a-world.md` (priority 2); `everything-is-a-component.md` (priority 0) moves the *components* and does not name these two worlds |
| 7 | sentinel <-> node | `rust/wa-sentinel/src/main.rs` (the request box, signal files) | the sentinel writes request files and signals a pid; the node reads them on its next tick | async by design, file-based | the sentinel's own bounds (`ALIVE_BOUND`, the deploy bound) | `wa-sentinel request`, the node's tick | not measured here | **KEEP** - the two processes must work while one of them is *down*, which a WIT seam cannot do (a component is only callable while the host runs it); the drop-box is the mechanism, documented in the sentinel's own header |
| 8 | Lua -> CLI subprocess | `rg 'host\.exec\("wa ' lua/core/*.lua` | nothing crosses this way today | - | - | - | **0 hits** | **KEEP (nothing to move)** - the Lua core does not shell out to `wa`; the calls it makes are `host.*` capabilities |

| 9 | the component hosts' own waits: hooks, mesh, selfloop, memory, stt | `rust/wa-kernel-runtime/src/hooks_host.rs`, `rust/wa-kernel-runtime/src/mesh_host.rs`, `rust/wa-kernel-runtime/src/selfloop_host.rs`, `rust/wa-kernel-runtime/src/memory_host.rs` and `rust/wa-kernel-runtime/src/stt_host.rs` (`DEFAULT_TIMEOUT_MS = 2_000` in each - the stt one arrived with the stt component landing after this table was written, and the row that keeps this table true named it on 27/11) | the host half of the `hooks`, `mesh` and `selfloop` worlds - a WIT seam already, with a private poll window | sync, then a timeout | **2 000 ms in three files** (`DEFAULT_TIMEOUT_MS`), the same 2 s as the index reads | the host bindings of those worlds | not measured here | **MOVE the WAIT (the seam is already WIT)** - brief queued: `component-hosts-share-the-wait.md` (priority 2) |
| 10 | browser control (CDP) in `wa-window` | `rust/wa-window/src/cdp.rs` (`LAUNCH_WAIT_MS = 40_000`, `PROBE_TIMEOUT_MS = 1_200`, `REQUEST_TIMEOUT_MS = 15_000`) | a websocket to a browser process the node launched - the outside world's protocol, like provider HTTP | sync request/response over a socket | three constants, none shared | the `wa-window` users (the UI's browser control) | not measured here | **KEEP** - the far side is a browser speaking CDP, not a part of wa; the law's own exception ("JSON stays where it is the outside world's format") applies, and a WIT seam cannot replace a protocol a third party owns |
| 11 | the queue crate itself, the fabric, the kv tests | `rust/wa-queue/src` (the durable queue `wit/queue` binds), `rust/wa-fabric/src/sim.rs:246` (a simulation), `rust/wa-kv/src/tests.rs:103` (tests only) | the queue is the *mechanism* these other rows use; the fabric's queue use is a simulation, and kv's is a test | - | - | - | - | **ALREADY WIT / KEEP** - `wa-queue` IS the `wit/queue` seam (`queue-provider`, `producer-consumer`); `wa-fabric`'s boundary is `wit/fabric/fabric.wit:305,312` (`fabric-client`, `fabric-admin`) and its only queue use is `sim.rs`; `wa-kv`'s is in `tests.rs`, so nothing crosses in product code |

## What is already queued on these surfaces (so nothing is queued twice)

* `everything-is-a-component.md` (priority 0) - the component move itself; it does not name the terminal/operations
  **worlds**, which is why row 6 is queued separately.
* `whatsapp-transcription-works.md` (priority 1) - the transcription *feature*; row 3 is about the **seam shape** of the same
  request, not the feature.
* `whatsapp-read-is-consistent.md`, `search-messages-finds-a-path.md`, `whatsapp-hold-not-silent.md` - the read's
  correctness; row 1 is about the boundary, not the answer.
* `graph-dormant.md`, `graph-index-tear-cause.md`, `graph-one-store-per-root.md` - the graph surface, already WIT (row 5).
* `operations-explain-and-survive.md`, `chat-view-round-2.md`, `esc-socket-per-thread.md` - terminal/operations behaviour;
  row 6 is about giving them a world.
* `wasi-only-plan.md` (priority 2) - the general plan; this inventory is the queue it asks for, surface by surface.
* `_orch/move-list.md` - measured line/churn counts per capability; every "measured cost" above that cites it is that
  file's number, not a new measurement.

## What this inventory does NOT claim

* It does not measure new costs. The numbers above are the tree's own (`graph.rs:37`) or `_orch/move-list.md`'s; the
  per-surface ledger counts (how often a caller past the 2 s wait was handed a job id) were **not** measured here, and a
  brief that moves row 1 should measure them first.
* It does not decide the WIT shape of a new world (terminal, OS process). That is the brief's job.

## The second table: one question, one owner (ARCHITECTURE.md law 17)

Each row is one question, the single place that answers it, the second answers found on 27/11, and where each is being
merged. A row whose answer is ALREADY ONE has no duplicate and exists so the law also shows what a clean answer looks
like. The KEEP list under the table is not an exemption from the law: each entry says why that number answers a DIFFERENT
question. `scripts/test-one-question-one-owner.mjs` derives the names from the tree and refuses when one is missing from
this table - which is how the list below got to twenty names instead of the four a first draft found.

| question | its ONE owner | duplicates found today | where each is being merged |
| --- | --- | --- | --- |
| How long may this wait? (a component call) | `rust/wa-component-wait` - `DEFAULT_WAIT_MS = 60_000`, `MAX_WAIT_MS = 300_000`, one knob `WA_COMPONENT_WAIT_MS`, and `expiries()` counting every window that expires | JOINED 27/11: `DEFAULT_TIMEOUT_MS = 2_000` in `hooks_host.rs`, `mesh_host.rs`, `selfloop_host.rs`, `memory_host.rs` and `stt_host.rs`, a `DEFAULT_TIMEOUT_MS = 120_000` in `wa-capabilities/src/codemode_seam.rs`, five per-host knobs, and the hooks component's `MAX_TIMEOUT_MS = 60_000` - six answers, two orders of magnitude apart; STILL QUEUED, their own briefs: `WAIT_MS` (whatsapp index 2 000, mail index 2 000) and `DOWNLOAD_WAIT_MS` (10 000) | done in this task (`change/component-hosts-share-the-wait`) for the six component answers. The five per-host knobs `WA_HOOKS_COMPONENT_TIMEOUT_MS`, `WA_MEMORY_COMPONENT_TIMEOUT_MS`, `WA_MESH_COMPONENT_TIMEOUT_MS`, `WA_SELFLOOP_COMPONENT_TIMEOUT_MS`, `WA_CODEMODE_COMPONENT_TIMEOUT_MS` and the one knob this task briefly introduced and then removed (`WA_COMPONENT_WAIT_MS`) name nothing that reads them: the window is a constant a caller passes in, and `rust/wa-kernel-runtime/tests/component_wait_shared.rs` sets every one of those names and proves none of them moves a value |
| How does a component get asked a question? | `wit/queue` (a job) and a WIT world for anything that returns a `future` | every `host.*` capability that enqueues a `wa_queue` job and then waits in the host for the answer | `whatsapp-read-waits-on-a-future`, `email-read-waits-on-a-future`, `stt-question-returns-a-future`, `terminal-and-operations-need-a-world` (queued) |
| How does a build get installed? | the installer - `scripts/deploy.sh` with `scripts/lib/install-record.sh` as the one writer of `installed.txt` and the one ancestry verdict | `/update` (`lua/core/update.lua`, its own stop-file, waiting-request and watcher facts), `wa update` on the CLI, `scripts/upgrade.sh` (its own bounds) | `update-is-one-line.md` (queued) |
| How is a turn drawn? | `lua/core/cli_view.lua` | `lua/core/chat.lua` draws the same turn again when it replays a resumed session | `the-turn-is-drawn-once.md` (queued by this task) |
| How do I run one statement and read the host's answer? | `lua/core/sql_answer.lua` - `M.run` returns `value, why` and never raises; each caller keeps its own policy and message | JOINED 27/11: `agent_control.lua` (`nil, why`), `done_gate.lua` (raise with a store prefix), `completions.lua` (raise), `backup.lua` (raise) each spelled the same pcall/decode/refuse | done in this task (`8801b311`) |
| What do we do when the database is locked? | `lua/core/sqlite_busy.lua` - `is_busy`, `patience_ms`, `retry` | `backup.lua`'s own `busy()` predicate (any text with "busy" or "locked") and its own `WA_BACKUP_BUSY_TIMEOUT_MS` knob (15 000) | done in this task (`d580fdf1`) |
| Who owns the install record? | `scripts/lib/install-record.sh` - `wa_record_install` and `wa_ancestry_verdict` | ALREADY ONE - `wa --version` reads that record instead of re-deriving the program and the tree separately | - |

### KEEP: each with the question it actually answers

* The memory host's MEASURED per-operation table (`rust/wa-kernel-runtime/src/memory_host.rs`, 1 500 ms for
  `recall`, 5 000 ms for `search_messages`, a floor for the rest): how long one MEMORY OPERATION may take, ten
  times its measured p99. That is a measurement of work, not the window a host gives a component call, so it stays
  with its numbers - and an operation it has never measured now takes the owner's wait instead of a private 2 000.
* `WA_GRAPH_PARSE_TIMEOUT_MS` (`rust/wa-graph/src/extract.rs:126`, default 30 000, 1-120 000): how long ONE syntax
  parse inside the graph component may take (`docs/GRAPH.md`). A parse is a bounded unit of work in the guest, not
  the window this node gives a component call, and a fix to one is not a fix to the other - so it is kept, with
  this reason, and it is not a duplicate of the wait above.
* `MAX_WAIT_MS` (`rust/wa-stt-remote/src/protocol.rs:418`, 15 000): the most a REMOTE peer may be asked to wait, as
  the protocol declares it - the peer's contract, not this node's window.
* `MAX_TIMEOUT_MS` (`rust/components/hooks/src/logic.rs`) is no longer a number of its own: it is
  `wa_component_wait::DEFAULT_WAIT_MS` read from the owner.
* `STATUSLINE_TIMEOUT_MS` (`rust/components/hooks/src/logic.rs:36`, 5 000): how long a statusline or hook SHELL command may
  run - a subprocess on this machine, not a component answer.
* `LAUNCH_WAIT_MS`, `PROBE_TIMEOUT_MS`, `REQUEST_TIMEOUT_MS` (`rust/wa-window/src/cdp.rs`): how long may a THIRD PARTY's
  debugger take to answer - the same exception the seam law makes for CDP, not a component call.
* `WASM_AGENT_UI_HEARTBEAT_TIMEOUT_MS` (`rust/wa-window/src/main.rs`): how long may the window's own client go quiet
  before it is considered gone - a liveness question, not a wait budget.
* `WASM_AGENT_ADMISSION_TIMEOUT_MS`, `WASM_AGENT_SUBAGENT_AWAIT_MS` (`rust/wa-capabilities/src/serve.rs`): how long may an
  HTTP client or a child process take - the OS and a foreign peer, not a component.
* `WA_WATCHDOG_WAIT_MS` (`rust/wa-sentinel/src/watchdog.rs`): how long may a rollback of a PID we do not own take; it is
  the same knob `upgrade.sh` reads, and the install owns it (`install-record.sh`/`upgrade.sh`), not the wait budget.
* `RELEASE_TIMEOUT_MS` (`scripts/landing-queue.mjs`): how long a `gh` child may take to publish a release - a foreign CLI.
* `ESC_CHILD_WAIT_MS` (`scripts/test-esc-stops-pty.mjs`, 30 000): how long a TEST row waits for a child PTY to be
  up before it asserts the key stopped it - a harness bound, not a window the node gives a call.
* `FULL_WAIT_MS` (`scripts/test-codemode-wait-bound.lua`), `SHARED_WAIT_MS` (`scripts/test-seam-inventory.mjs`), 
  `WA_EXPERIMENT_AWAIT_MS` (`scripts/experiment-tool-choice.lua`): test and experiment harnesses; they assert ABOUT the
  budget and must not read it as a value, or the test would move with the bug.

