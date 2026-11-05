# Queue — one durable queue for every kind of work

Status 2026-11-05: `rust/wa-queue` exists and is tested; `wit/queue/queue.wit` is a **draft**. No
component is served by a host yet. Related: [KERNEL.md](KERNEL.md) (the component contract),
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

## What the host must add to serve `wa:queue`

Prerequisite: the WASI 0.3 / wasmtime 50 upgrade (native `future`/`stream`, async component
imports). Today wasmtime 37 has no async component ABI, so the draft cannot be served as written.

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
