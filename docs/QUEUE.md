# Queue — one durable queue for every kind of work

Status 2026-11-06: `rust/wa-queue` exists and is tested, and the host serves `wa:queue` to
components (`rust/wa-host/src/queue_host.rs`) over it: a `wa_queue::Queue` per call in the
component's own kv (`q/` inside it), a manifest `queue` grant per interface and per namespace, a host
sweeper, and alerts written to the process log and published on the bus topic `kernel.queue.alert`.
`wit/queue/queue.wit` is expressed with WASI 0.3 `async func`s plus one `stream<list<u8>>` (the
draft's `future<T>` spelling is gone; see "How the host serves it" for what each of the eight
requirements below turned into, and what is still open). Related: [KERNEL.md](KERNEL.md) (the component contract),
[COMPONENTS.md](COMPONENTS.md), [SERVICE-COMPONENTS.md](SERVICE-COMPONENTS.md) (long-lived service
components), [JOBS.md](JOBS.md) (automation definitions — a different thing),
[OPERATIONS.md](OPERATIONS.md) (one supervised process), `wit/queue/queue.wit`,
`rust/wa-queue/src/tests.rs` (the semantics, executable).

## Why a shared queue

Three callers already need the same thing, and today each one grows its own:

| caller | what it needs |
| --- | --- |
| WhatsApp audio | pending audio to transcribe: priority between a live voice note and a backlog, freshness ("never transcribe something older than the window"), retry cost per failure kind, coalesced alerts when audio will not be transcribed |
| WhatsApp transcripts | ready parts to post: never post what has gone stale, retry the send, one alert per failed post |
| OCR, agent sub-tasks, future channels | the same shape again with different names |

The semantics are in `connectors/whatsapp/audio_queue.go` and `freshness.go`, and they are not
WhatsApp-specific: *enqueue → lease → heartbeat → done/fail*, *drop stale work without running it*,
*retry with backoff, dead-letter what keeps failing*, *report once per job, batched and rate
limited*.

## What already exists, and what this adds

| crate | provides today | overlap with `wa-queue` |
| --- | --- | --- |
| `rust/wa-jobs` | SQLite store of automation **definitions** (`jobs`), **deliveries** (queued/running rows, unique `(job_id, revision, event_id)` dedupe, a `claim` that only runs one delivery per job, `recover` marking `running` → `unknown` on restart, `defer`) | The delivery table *is* a queue with dedupe and a claim, but no lease expiry, no backoff, no freshness, no alerting, no per-queue concurrency, and its recovery is manual (`recover` needs a human to reconcile). Reused ideas: dedupe by producer key, the revision pin, `finish(id, state, detail)` and `defer`. |
| `rust/wa-operation` | **one** supervised process: deadline, output cursors, cancellation, settlement, a boot lease file | Not a queue: no ordering, no retry, no persistence of the work list. Overlap only in vocabulary (`settled`, `unknown`, "never retry an ambiguous effect"). |
| `connectors/whatsapp` (Go) | the reference semantics: `audio` rows as a priority queue with `failures`/`next_attempt`, `outbox` with freshness, `alerts` with `UNIQUE(account,generation,chat,source,kind)`, `alertMinGap`/`alertBatchMax`/`alertMaxAge` | This is what the crate is modelled on; the mapping is below. |

`wa-queue` is a pure library: no wasmtime, no threads, no I/O, no dependency at all. It is a set of
operations over a `Kv` and an injected clock, so the same code runs in the host today (behind Rust
functions) and in a queue-provider component after the WASI 0.3 upgrade.

## Shape

```
producer ──enqueue──▶ │  Kv: job records ("j/<id>")          │ ──take/heartbeat──▶ worker
                      │      ordered index ("i/<q>/<R|L>…")   │ ◀──done/fail/progress──
admin ────stats/dead──▶│      dedupe claims ("d/<q>/<key>")  │
         alerts        │      progress      ("p/<id>/<seq>")  │
         requeue       │      alerts        ("a/<id>/<kind>")  │
                      │      counters      ("s/…")            │
```

- **The job record is the truth.** The index, the dedupe claim and the alert keys are derived. A
  crash between two writes leaves them out of step, which `take` self-heals (it re-reads the record)
  and `repair()` fixes in bulk.
- **Nothing in memory.** A restart is a new `Queue` over the same bytes; leases are not trusted,
  they are compared with the clock.
- **One writer per namespace.** The kernel's `kv` grant is per component, which is exactly that.
- **Bounded ordering.** Ready index keys are `<inverted priority><id>`, so a scan yields higher
  priority first and FIFO inside one priority. A job with a future `not_before` does not hide a due
  job behind it: `take` skips it and keeps scanning.

## Semantics

| operation | guarantee | what a crash does |
| --- | --- | --- |
| `enqueue` | dedupe key claims first, then the record, then the index; the same key in the same queue returns the same id (`dedupe_hit`) | a crash after the claim but before the record loses that one job; the next enqueue with the key allocates a new id. Two jobs for one key is impossible. |
| `take(queue, worker, lease)` | one job, one lease, at most `concurrency` in flight per queue (`AtLimit` backpressure); expires stale jobs instead of returning them | the lease is only in the Kv; after the clock passes it, any `take`/`sweep` recovers the job |
| `heartbeat` | extends the lease only for the worker that holds it; `LeaseLost` otherwise | — |
| `done(id, result)` / `done_by(id, worker, result)` | settled at most once; the second settle is `LeaseLost`; results over `max_result_bytes` are refused, never truncated | a done that crashed before the record write leaves the job leased and it is retried (at-least-once) |
| `fail(id, reason)` | attempt counted, `not_before = now + base·2^(n-1)` capped; at `max_attempts` the job is dead-lettered with one `dead` alert | the attempt is durable before the lease is cleared |
| `progress(id, chunk)` | append-only, sequence numbered, bounded entries and bytes; readable incrementally (`progress_since`) | a progress write that failed is an error, never a silent gap |
| `expire_stale()` | every **unleased** job past `fresh_until` becomes `expired` and is recorded; nothing runs it | `take` applies the same rule itself, so a sweeper that never ran cannot cause old work to run |
| `sweep()` | expired leases, stale jobs, timeout alerts, retention — idempotent | safe to run on every tick |
| `next_alerts()` | one batch at most per `min_gap_ms`, `batch_max` items, ready alerts older than `max_age_ms` dropped; items beyond the cap stay ready and are reported as `overflow` | items are marked sent after they are read; a crash between read and send re-sends the batch, it does not lose it |
| `requeue` | dead letters only; attempts reset; **freshness kept** unless `refresh_fresh` | — |
| `reap()` | terminal records older than their retention go, with their progress and their dedupe claim | the dedupe key becomes usable again |
| `repair()` | rebuilds index and dedupe from the records, drops orphans | — |

Freshness, precisely ("never repost old"):

1. `take` drops a stale job instead of returning it — the safety net, independent of any timer.
2. `expire_stale` (called from `sweep`) does it in bulk for the operator's stats.
3. A job that is **leased right now is left alone**: the work in flight is still fresh, and
   killing it would discard a transcript that is already being produced. When its lease lapses, the
   same rule applies.

A leased job past `fresh_until` that a worker is still holding is not expired under it; the expiry
happens when the lease ends. That is the Go connector's `inflight` exception, kept.

## Partial results

`progress` is append-only and per job, so a streaming worker (segments of a transcript, chunks of an
OCR page) publishes as it goes and a reader can poll `progress_since(job, after, limit)` without
re-reading everything. It is bounded (entries and bytes) so a runaway worker cannot use the Kv as a
log sink; going over the bound is a refusal (`ProgressFull`), not a silent truncation. `reap` retires
the chunks with the job.

## Alerts

An alert is a record, not a side effect: one per `(job, kind)` — `expired`, `timed_out`, `dead` —
which is the general form of the WhatsApp connector's `UNIQUE(account,generation,chat,source,kind)`.
The queue never formats or sends anything; `next_alerts()` returns the batch and the caller (a
channel component, the operator log) delivers it.

| knob | default | WhatsApp value |
| --- | --- | --- |
| `min_gap_ms` | 60 000 | 60 000 (`alertMinGap`) |
| `batch_max` | 12 | 12 (`alertBatchMax`) |
| `max_age_ms` | 6 h | 6 h (`alertMaxAge`) |

Two differences from the connector, both deliberate: an alert over the batch cap is *kept* for the
next batch instead of being counted as `+N` and marked sent (a count in a message is not a record),
and a reason is sanitized to one bounded line before it is stored (`rust/wa-queue/src/queue.rs`),
so a caller that pastes an error message cannot inject text into the log.

## WhatsApp transcription on top of it

| connector today | `wa-queue` |
| --- | --- |
| `audio` row `state='pending'` with `failures`/`next_attempt` | job in queue `wa.stt`; payload is the media **handle** (`chat\x00id`), not the audio bytes |
| `UNIQUE(account,generation,chat,id)` prevents a second transcription | `dedupe_key = "{account}/{generation}/{chat}/{id}"` |
| `m.sent >= now-freshSeconds`, `freshSeconds` default 300 s | `fresh_for_ms = 300_000` (`WA_WHATSAPP_FRESH_SECONDS`) |
| priority SQL: never-failed first, fresh oldest-first, old backlog newest-first, failed last | `priority`: 20 fresh and unattempted, 10 backlog, 0 after a failure; the FIFO tiebreak gives conversation order inside each band |
| `maxComputeFailures = 6`, tiers of two decodes | `max_attempts = 6`; the worker picks its tier from `attempts` |
| `backoff(30s, 1h, failures)` for decode failures, `backoff(1m, 10m, attempts)` for environment | `RetryPolicy { base_ms, max_ms }` per queue (the two kinds stay two queues or two bands, not one knob) |
| `state='expired', reason='stale_over_5m'` + `audio_expired` alert | `expire_stale` → `expired` record + `expired` alert, reason `fresh_until passed before it ran` |
| outbox rows with `created`, expired at `stale_over_5m` + `post_expired` alert | queue `wa.post`, `fresh_for_ms = 300_000`, one job per `(chat, source, part)`, dedupe on the same tuple |
| lane picked by a worker loop; `inflight` map | `take(queue, worker, lease)`; the lease is the `inflight` set, and it survives a restart |
| transcript segments | `progress(job, segment)`; the final text is the `done` result |

What stays outside the queue, on purpose: chat holds and fences (`computeFence`, `chat_holds`,
`target_fences`) decide *whether* work may run; the queue only decides *when* and *in what order*. A
fenced job is `fail`ed with the fence reason (or never enqueued), and the hold is re-checked by the
worker after compute, as the connector does today. Same for the outbox `send_id` and reply
semantics: the queue carries the job, the channel owns the send.

## Phase 2 — workers on another node

A queue provider on the node that owns the journal, workers anywhere on the relay:

- A remote worker imports only `worker` for the granted queues; it can take, heartbeat, settle and
  write progress. It never sees the producer's dedupe space or the admin surface, so a compromised
  worker cannot requeue its own dead letters or enqueue on someone's behalf.
- **Leases are measured on the provider's clock**, never the worker's: `heartbeat(extend_ms)` is a
  duration, not an absolute time. Clock skew then shortens or lengthens nothing except by the
  network round trip, and a node with a wrong clock cannot steal or hold a lease.
- Keep payloads small: a remote `take` on a job whose payload is a media blob would move bytes over
  the relay. The payload is a handle (`chat\x00id`, a path in the channel's own namespace, an
  object id), exactly as above, and the worker fetches the bytes through the channel's own
  capability. Inline bytes stay fine for small jobs (an OCR page, a prompt).
- At-least-once, not exactly-once: a worker that dies after doing the work and before `done` is
  retried. That is why `done` carries the result and every effect the worker performs must be
  named idempotently (post with the outbox `send_id`, transcript written under the message id).
- Progress streams make a remote job observable while it runs, so a slow node is visible as
  `leased` + progress rather than as a missing result.
- Migration: the lease is the only thing that must not exist on two nodes at once, and it is one Kv
  key on the provider. A node that joins or leaves changes nothing but who calls `take`.

### What phase 2 has (queue `stt.requests`, speech)

`rust/wa-stt-remote` — a library with no wasmtime, no threads and no I/O of its own — is the part of
phase 2 that is not the host's and not the component's. It is built and tested (`cargo test -p
wa-stt-remote`, 18 tests, and the gate runs it in `scripts/test.sh`); the node half it plugs into is
`rust/wa-kernel-runtime/src/stt_node.rs` (2026-11-06), and what is still open is listed at the end of
this section.

| piece | what it decided |
| --- | --- |
| `request::SttRequest` | the job payload: the audio (inline at most 256 KiB, otherwise a **short-lived fetch handle**), the language snapshot, `fresh_until`, the chat/message ids and the account/generation for the dedupe key. **No text field at all** — an unknown key is a refusal, not something dropped, so a transcript cannot be smuggled into a job record. `Debug` prints sizes and ids, never bytes |
| `protocol::Envelope` + `Admission` | one signed node call per operation (`take`, `audio`, `beat`, `seg`, `done`, `fail`), the transport's existing `<action>\|<node_id>\|<ts>\|<sha256(body)>` signature, and the checks a producer makes before it answers: target, **caller must be one of the owner's own nodes**, timestamp inside the skew window, signature, and `rid` not replayed. Refusals are fixed words |
| `policy::Preference` | remote first when it is online and its recent decode is faster; the local worker holds back for `fallback_after_ms` (default 3 s) and then takes the job itself; remote offline or measured slower means no wait at all. Latency is an EWMA with a sample count and a 10-minute lifetime, so a cold or an old estimate is not evidence |
| `worker::Decoder` | the half both workers share: freshness checked **before** the decode and **before** the settle (a job that goes stale in flight is dropped, never posted late), the lease extended before each segment is published, segments streamed as progress, one settle, and the audio buffer erased and the handle discarded after the job |
| `worker::RemoteWorker` / `producer::LocalWorker` | the remote long-poll over a `Transport` (implemented by `sim::Relay` in tests; by the node's signed call in production), and the local poll that applies the grace |
| `producer::Producer` | enqueue (dedupe key, priority 20/10/0, freshness counted from `sent_at`, 6 attempts), `serve_audio` (only the worker that **currently holds the lease**, only while the job is fresh and the handle unexpired), `discard_audio`/`purge_audio` |
| `metrics` | counters and two lines (`stt-remote v=1 …` totals, `stt-job v=1 job=… by=… took_ms=…`) built from numbers: ids and timings only, never text |

A note on what "faster" is measured on: the remote reports the recognizer's own elapsed time in its
`done`, so the producing node compares like with like instead of the whole relay round trip.

### The node half (2026-11-06)

`rust/wa-kernel-runtime/src/stt_node.rs` is the part the library deliberately does not own — the
queue, the audio store, the clock and the recognizer are the node's:

| piece | what it does |
| --- | --- |
| the queue | one `wa_queue::Queue` over `<components>/stt.state/kv.sqlite`, sub-prefix `q/`, and the audio behind fetch handles under `a/` — the same file, so the same durability and the same owner. A new `Queue` per call, as `queue_host` does: the library keeps nothing in memory |
| the producer's worker | a thread running the library's `LocalWorker::poll_once` (the `Preference` grace, the lease cadence, both freshness checks and the settle are the library's), with a `Recognizer` over the node's warm worker (`service_stt`). It deletes a job's audio when it settles, and a 15 s sweep purges what nobody settled |
| the relay handler | `stt_node::call` takes one admitted call from `lua/core/server.lua#node_capability` (capability `stt`, host function `host.stt_call`). The outer call is the transport's normal signed call (`call\|<node>\|<ts>\|<sha256(body)>`, verified by `verify_peer`); the library's `Envelope` rides as its arguments, and `Admission` re-checks target, caller, timestamp and `rid` before the queue is touched |
| the worker role | `stt_node` runs the library's blocking `RemoteWorker::poll_once` on a thread. Its `Transport` does not sign: it *tunnels* each `Envelope` to the node's Lua (`host.stt_pending` / `host.stt_deliver`), where `nodes.lua` signs and sends it. The node key stays in the interpreter, and the decision logic stays in the library |
| the component's slot | `service_stt::submit` enqueues (a `Submission` with synthesized ids and `sent_at = now`), and every progress entry and terminal state a worker writes is mirrored into the `wa:kernel/speech` slot the component polls — one view for a remote decode and a local one |
| the operator view | `host.stt_admin` (`configure`, `status`, `job`, `sweep`, `counters`) and the `services` tool action `stt`: the role, the attached workers with their take/done/fail counts and average decode, the remote vs local split, the lease state and the last settled jobs — ids, states and durations only, never a transcript |

The configuration is a request the node's Lua sends on boot: `{action: "configure", me,
owner_nodes, producer, worker, producer_id, …}` from `lua/core/stt.lua`, which is where the role comes
from (`WASM_AGENT_STT_ROLE` = `producer` by default, `worker`/`stt_worker`, `both`, `off`; the
producer's selector in `WASM_AGENT_STT_PRODUCER` or the second line of `~/.wasm-agent/node.stt`;
lease, heartbeat, grace, freshness and latency lifetime from `WASM_AGENT_STT_*_MS`). A node with no
role configured keeps the pre-queue path.

Two properties a reader should not have to infer:

- **Presence, not a feed.** A producing node treats a worker as attached for 90 s after its last
  *admitted* `take` (an empty one counts), so the grace applies only to a node that is polling. A
  worker that has just joined is admitted on the next tick: a refusal counted as `unknown_caller`
  makes the producer re-read the rendezvous at once instead of waiting out the 30 s refresh. The
  first note after a cold start can still be decoded locally — that is the policy's named risk.
- **The kernel's freshness window starts at the node, not at the message.** `wa:kernel/speech` carries
  audio, mime and language and nothing else, so `service_stt::submit` dates the job at submission. A
  caller that knows the chat and the send time (the WhatsApp component would) uses `host.stt_submit`
  and gets the real window; that is the remaining step 1 below.

Still open in phase 2 (each is a piece this change did not take):

1. **The component's own enqueue.** `rust/components/wa-whatsapp`'s `queue.rs`/`recognize.rs` still
   own their kv queue and their warm recognizer. They reach `stt.requests` *through*
   `wa:kernel/speech` today; enqueueing directly with the real chat/message ids and `sent_at` needs
   those fields on the speech interface (`wit/kernel`), which this change did not touch.
2. **A managed/enrolled `stt_worker`.** A peer call requires the caller to be a master in the
   rendezvous' view. An enrolled guest can be one only once the fabric grants it (the capability is
   already in the enrollment allow-list; the role rule is not).
3. **A blocking `take`.** The worker polls (`wait_ms = 0`); the producer answers at once. WASI 0.3
   futures would make a real long poll expressible, and the provider would then need a wake path per
   queue, which the Kv alone does not give.
4. **Two-node proof in the gate.** `scripts/test-stt-two-nodes.sh` is in `scripts/test.sh` (and skips
   with 77 without a node binary or python3); it is not in the minute-scale fast path, which runs
   `scripts/test-stt-role.lua` instead.

## How the host serves it

Prerequisite met: wasmtime 50 with `component-model-async`. The requirements below are kept as they
were written - they are the contract - and each one now names what the host does, or that it is
still open:

| # | requirement | built? |
| --- | --- | --- |
| 1 | a `Kv` adapter | `rust/wa-kv`: `Store` + `Namespaced`, shared with the bus and the state crate; the queue's keys live under `q/` inside the component's kv |
| 2 | a clock | `wa_queue::SystemClock` in the host, `FixedClock` in tests; nothing in the provider reads the wall clock itself |
| 3 | a grant | `queue_host::Grants` reads `{"interfaces": […], "namespaces": […]}`; a malformed grant refuses the start, an ungranted interface or queue is `refused`, a `wa.*` namespace covers one more segment |
| 4 | a provider | the host serves `producer`/`worker`/`admin` (bindgen world `wa:queue/consumer`); the sweeper runs every 15 s; stopping a component flushes nothing and its lapsed lease is recovered by `take` |
| 5 | alert delivery | the sweeper drains `next_alerts()` per component: one bounded log line, and a `kernel.queue.alert` fact on the bus (last 64 retained). An `admin` consumer may still call `next-alerts` itself |
| 6 | scope by queue | `gate_job` loads the job and refuses it unless its queue is granted; the worker calls also require the queue named in the call to equal the job's own |
| 7 | observability | the `admin` interface plus `queue_host::status()` (counts per component and granted queue); **not** wired into `/health` or the UI, which this change does not touch |
| 8 | two-node proof | **in process**: `rust/wa-stt-remote`'s simulation runs two nodes (two queues, two clocks, one relay speaking the real signed wire) and proves remote-wins, remote-dies-mid-job → local finishes, stale-never-decoded and the counters. One-node, end to end, is `rust/components/svc-queue-echo` + `scripts/test-queue-bus-state.lua` (produce -> consume -> done, dedupe, the progress stream, the admin counts, a refused queue). **Open**: the host route a real remote worker would call — see "What phase 2 has" above |

Two things a reader should not have to infer: `progress(job-id, after)` is a *snapshot* stream (the
chunks that exist when it is opened, then it ends), because the library keeps no wake path per job;
and `Policy::default()` is what the provider runs with - no freshness bound and no timeout unless the
producer's request asks for one, because a host-wide default would be a guess about every queue on
the node.

## What the host had to add to serve `wa:queue` (the contract the provider meets)

1. **A `Kv` adapter.** `wa:kernel/kv` is `get`/`set`/`delete`/`delete-prefix`/`scan(prefix, cursor,
   limit)`. The queue needs `scan_prefix` without a cursor and in key order, which is `scan` paged to
   the end; `MemoryKv` and `Prefixed` in `rust/wa-queue/src/kv.rs` are the shape to implement, and
   `Prefixed` is how the provider gives each component its own namespace inside one store.
2. **A clock.** `wasi:clocks/monotonic-clock` is a duration, so the provider needs the kernel's wall
   clock (`SystemClock` in the crate is for the host, `Clock` is the seam). Everything the queue
   decides is a function of this value, so a test host can inject `FixedClock`.
3. **A grant.** A `queue` capability in the manifest and the registry definition, per interface,
   with namespaces: `{"queue": {"interfaces": ["producer"], "namespaces": ["wa.stt"]}}`. The kernel
   refuses an interface the grant does not name, and a queue name the grant does not cover
   (`refused`). A component's own raw `kv` grant must not overlap a queue namespace: two writers in
   one namespace break the invariants this library keeps.
4. **A provider.** Either the kernel serves `wa:queue` from this library directly (simplest), or a
   component exports `producer`/`worker`/`admin` over its `kv` grant. In both cases it is a service
   component (`wa:kernel/lifecycle`): on a tick, `sweep()`; when it stops, nothing to flush (all
   state is already in the Kv). Start-by-imports means a worker component starts once the provider
   reports `ready`.
5. **Alert delivery.** `next_alerts()` is a record drain, so something has to deliver it: the
   channel component formats the batch and sends it through its own capability (the WhatsApp log
   posts to the account's own chat). The kernel should not grow a messaging path for this.
6. **Scope by queue, not only by namespace.** `wit/queue` names the queue on every worker call, but
   the library's `heartbeat`, `done`, `fail` and `progress` take a job id only: inside one namespace
   a worker granted queue A could settle a job of queue B. The namespace (`Prefixed`) is the grant
   boundary the crate keeps, so the provider compares `Job::queue` with the granted queue before it
   calls the library. That check must exist before `worker` is granted to a remote node.
7. **Observability.** `stats(queue)`, `dead_letters(queue, n)`, `alerts()` and the alert counters
   behind `/health` and the UI: counts and ids only, never payloads or reasons that could carry
   text. The process log gets `queue`, `counts`, `job id` — the same rule as `docs/OBSERVABILITY.md`.
8. **Two-node proof.** Phase 1 is one node: the same Rust type behind host functions, wired to
   whatever the WhatsApp component uses today, with the Lua `jobs`-style surface as the operator
   entry. Phase 2's check is a real worker on another node taking a job over the relay and settling
   it, which is also the only way to trust the lease-over-relay arithmetic.

## Open questions

- **Dedupe lifetime.** Today a claim lives as long as the job record, so a finished job still
  answers `dedupe_hit` until `reap` retires it. The alternative (release on settle) would allow a
  second job for a key that already ran; that is the wrong default for "never transcribe the same
  audio twice", but it is a policy choice a caller may want.
- **Timeout alert for work that is merely waiting.** A ready job past its deadline may mean "the
  producer is faster than the workers" rather than "something is stuck". The alert says which state
  it was in; whether a starved queue should alert at all is a per-queue policy.
- **Priority aging.** A stream of high-priority jobs can starve the backlog band indefinitely. The
  WhatsApp connector avoids it by banding within a 15-minute window; a generic aging rule (raise
  priority with age) needs a measurement first.
- **Progress shape.** Chunks are opaque bytes with a sequence number. A typed segment record
  (`start`, `text`, `done`) would let a reader render a transcript in order without knowing the
  producer's encoding; it also fixes the encoding in the contract, so it waits for the second
  consumer.
- **Blocking take.** `take` returns `empty`; over the relay a worker polls. WASI 0.3 futures make a
  blocking `take` expressible, but a provider then needs a wake path per queue, which the Kv alone
  does not give.
