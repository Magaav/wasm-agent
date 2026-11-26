# stt becomes a component — report (move-list row 16)

Branch `change/stt-becomes-a-component`, base origin/main **e64ab009**. Commits:
**18d00ce6** (the `stt` feature entry — registration only, its own commit) and **2835577a** (the move).
Node avell; worktree `/home/victor/Work/missions/stt-becomes-a-component/wt`; `CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-stt-component`.
Nothing landed: the v0.1.2 tag rule stands.

## What the measurement found

The cut was already drawn by the crate. `rust/wa-stt-remote` says of itself that it is *"the part that does
not belong to the host or the component… no wasmtime, no threads and no I/O"*; measured, it builds for
**wasm32-wasip2 in 5 s**, and its two path dependencies are pure (`wa-queue`: none; `wa-fabric`:
`wa-queue` + `serde_json`). So unlike mesh, the rules crate could go into the guest as it is.

| where | lines | what | a guest? |
|---|---|---|---|
| `wa-capabilities/src/stt.rs` | 72 | the five capability entries (`capabilities.rs:285-289`) | no — registration is another worker's file |
| `wa-kernel-runtime/src/stt_node.rs` | 1,362 → 1,424 | the `Runtime`: queue over kv, worker **thread**, clock, recogniser, relay POST through Lua's `host.sign` | the wire decisions: yes (**done**); the rest: no |
| `rust/wa-stt-remote` | 3,777 | payload, wire protocol + admission, preference policy, metrics, producer/worker loops | the pure modules: yes |
| `lua/core/stt.lua`, `server.lua` | — | the pump (`stt_pending` → sign → `nodes.lua` → `stt_deliver`) | no — the key is the interpreter's |

## The change (2835577a)

* **`wit/stt/stt.wit`** — package `wa:stt@0.1.0`; `types` carries the `envelope` record
  (`op/from-node/to/ts-ms/rid/body-json`), the thirteen-case `refusal` variant mirroring the crate's
  `Refusal`, the `refusal-word` record (a refusal's own word plus the wire bytes) and `admitted`
  (`call | refused`); `interface stt` exports `admit` (async), `reply-ok` (async) and `sanitize` (sync, with its reason
  line); `world stt-component` exports `stt` and **imports nothing**. It carried `encode` and
  `signature-message` at first; both are gone, because a producing node neither composes nor signs an
  outbound envelope (the worker inside `wa-stt-remote` does, beside the signer) - dead surface, removed
  with the reason written where a reader would look for it.
* **Async, per Victor 26/11** — the four waiting calls are `async func` (short calls included) and the
  guest impl is `async fn`; `sanitize` is sync with its reason line in the file. Cancellation (drop the
  future), backpressure (nothing to declare, and why) and the absence of a stream of its own (the queue owns
  `progress`) are written in the interface's doc block. It builds on the pin — wasmtime 50 with
  `component-model-async`, wit-bindgen 0.63 — so nothing was discovered by failing.
* **`rust/components/stt`** — cdylib over `wa-stt-remote`; the `rid` ledger lives in the component
  (rebuilt when the node id, owner list or skew changes), refusals are rendered to wire bytes **in the
  guest**, and the caller check is ordered before the ledger exactly as the node module ordered it.
* **`rust/wa-kernel-runtime/src/stt_host.rs`** — the loader and `available()` in mesh's shape, **one**
  instance for the process (the ledger is the seam's state; every `stt_node` call already serialises on its
  runtime mutex), and the four async calls on wasmtime's async path (`run_concurrent` inside
  `tokio::time::timeout`, the three error layers flattened in one named `flatten`). It shares
  `components::engine()` with every other seam: the first shape gave it an engine of its own, and wasmtime
  50 then reported `Config::async_support` as **deprecated, "no longer has any effect"** — the async call
  path runs on the shared engine, so there is no second engine and no second epoch ticker in the node.
* **`stt_node.rs`** — `routed()` asks the **feature resolver** per call (`wa_features::status("stt")`;
  `WA_STT_COMPONENT` is the resolver's override, never a product env read), `handle` tries the guest
  first, a refusal's word feeds `metrics.record_refusal_word` (the crate's own spellings) and its bytes
  become the reply the peer reads; `Err` logs one line per (operation, reason) and runs the native rule,
  which is unchanged below the new branch.
* **`wa-stt-remote`** — three additions and nothing else: `Admission::me()`, `Admission::owner_nodes()`,
  `Metrics::record_refusal_word()` (the host must not reconstruct a case to count it).
* **`components.lock`** — first `stt` pin:
  `stt bc7db7b0f63f3187edb02490ba73dca0d655ce70991eda791e14841a10f63d73 146696`, two builds by
  `scripts/build-components.sh stt` at rustc 1.99.1 / `/tmp/wa-component-build/src`, same sha256 both
  times (the first pin, 152,942, carried the two exports later removed).

## Numbers (measured)

| | before | after |
|---|---|---|
| `target/release/wa` | 79,722,024 B | **81,135,888 B** (**+1,413,864**, +1.8%) |
| cold `cargo build --release -p wa-host` | 192 s | 192 s |
| `stt.wasm` | — (no component) | **146,696 B** pinned |
| `stt_node.rs` | 1,362 lines | 1,424 |

The +1.8% is the async rule's price and it is the host's, not the seam's: wasmtime 50 with
`async_support` plus the tokio runtime are now linked into `wa` for one seam that answers a few
microseconds of work per call. Reported rather than hidden, because it is the largest number in this move.

## Gates

* **The golden** — `scripts/test-stt-seam-answers.lua` + `fixtures/stt-seam-answers.txt`: twelve
  deterministic requests over all five `host.stt_*` capabilities (the pump's nulls, three refusal
  sentences, the status view, a role configure, a bad role, a job, a sweep, a non-JSON body), recorded on
  the **pre-move build** (18d00ce6) and compared byte for byte: **12/12 identical** on the new build with
  the component absent *and* installed. (`elapsed`-class timings are the only fields folded.)
* `cargo test -p wa-stt-remote`: **23 passed, 0 failed**.
* `cargo test -p wa-kernel-runtime stt_node::`: **8 passed, 0 failed**.
* **`scripts/test-stt-seam.sh`** (new row, wired into `scripts/test.sh`): builds the component, runs the
  crate's tests, runs the seam's happy-path test against that artifact (**1 passed**), and holds
  `scripts/test-stt-seam-answers.lua` to the fixture on **both** paths — native and component — 12/12
  identical each time. `stt seam: ok`.
* `scripts/test-stt-node-script.lua`: ok (the status view). `scripts/test-stt-role.lua`: **79 checks ok**.
* `scripts/test-stt-two-nodes.sh`: **FAILS, and fails identically on the pre-move binary** —
  `FAIL: could not find the worker node's process id`. Pre-existing in this environment, not this change:
  logs `two-nodes-base.log` and `two-nodes-routed.log`.

## What is not done, and why (measured, not deferred by preference)

* **The routed path is proven at both levels.** In process, `stt_host::tests::the_guest_admits_one_call_and_refuses_its_own_replay`
  drives the seam against the built artifact: the guest decodes a real `take` envelope, refuses its own
  replay from its own ledger (`replayed_request` — the point of holding one instance) and refuses a caller
  that is not one of the owner's nodes (`unknown_caller`). At the node's own level,
  `tests/stt_node_routed.rs` — a **test target of its own process**, because the switch it needs
  (`WA_COMPONENTS_DIR`) is process-global and setting it inside the module's binary made two neighbouring
  tests share the guest's one instance (measured) — configures a node (`me: producer`, owners
  `producer, worker`), installs the artifact with its pin, submits a note, and sends the same wire call the
  two-node row sends: the guest **admits** the take, the replay is refused from the component's ledger, and
  `stt_node::fallbacks()` stays empty. Both run from `scripts/test-stt-seam.sh`.
* **`reply-ok` is routed** (the reply is the other half of the wire this layer owns); **`encode` and
  `signature-message` are not in the world at all**, because the producer composes and signs inside
  `wa-stt-remote` where the signer is - routing those would move that loop, a change to make with the
  two-node row green under it.
* `submit`, `admin`, `pending`, `deliver` stay native: they are the queue's own operations (kv, leases,
  the audio store, the worker thread) and cannot enter a guest — the same measured line as mesh's transport.

## Texts to approve

1. `[stt] {operation} decided natively: {reason}` — one line per (operation, reason) when the component
   cannot answer; operator-facing, the same shape `mesh` prints.
2. `component_not_configured` — the seam's name for "this node has no identity to admit with".
3. `component_answer_invalid:unknown_op`, `component_answer_invalid:refusal` — a guest answer this host
   cannot read; never seen on a healthy node.
4. `component_unavailable:`, `component_wedged:`, `component_failed:` — the classifications the seam
   already used in mesh and codemode, reused verbatim.

No model-facing string changed: the five capabilities' answers are byte-identical to the pre-move build.
