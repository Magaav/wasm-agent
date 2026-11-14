# Bus — facts fan out, work does not

Status 06/11: library built and tested (`rust/wa-bus`, 31 unit tests, no dependencies); WIT in
[`wit/bus/bus.wit`](../wit/bus/bus.wit) parsed and resolved with wasm-tools 1.263.0, **served** by
`rust/wa-kernel-runtime/src/bus_host.rs` on `wa:kernel@0.2` (WASI 0.3): one `wa_bus::Bus` per node, the ACL
built from the components' manifest grants, `source` set by the host, a subscription delivered to the
guest as a `stream<event>`, and `revoke_owner` on stop. See "Integration" below for what is wired and
what is not.

The queue is **work**: one consumer, durable, an event is claimed, executed and done —
[JOBS.md](JOBS.md), [OPERATIONS.md](OPERATIONS.md). The bus is **facts**: many consumers, no claim, no
retry, no exactly-once. `whatsapp.transcript.ready` reaches the agent, the search index and the logger
without the WhatsApp component knowing any of them exists. A bus event that nobody wants is not a
problem; a queue event that nobody consumes is.

Rule of thumb: *if losing it silently breaks a promise, it is work (queue); if losing it only makes a
view stale, it is a fact (bus).* A consumer that must not miss one, subscribes with `block` and/or a
durable topic.

## Topics

Dotted path, first segment = the **namespace** (`whatsapp.transcript.ready` → namespace `whatsapp`).
Segments are `[A-Za-z0-9_-]`, 1–64 bytes, alphanumeric at both ends, ≤ 16 segments, ≤ 256 bytes. A
topic is therefore also a legal kv key fragment, a file-name-safe string and a WIT string, with no
escaping anywhere. Refused, never normalised: `a..b`, `a.`, `.a`, `a b`, `a/b`, `a*b`.

| pattern | matches | does not match |
| --- | --- | --- |
| `whatsapp.transcript.ready` | exactly that topic | `whatsapp.transcript` |
| `whatsapp.*` | `whatsapp.transcript.ready`, `whatsapp.x` | `whatsapp` itself, `whatsappx.y` |
| `*` | everything (needs a grant) | — |

`.*` is only legal as the last segment; `a.*.b`, `*.a`, `a.b*` are refused. The wildcard means "at
least one more segment", so `whatsapp.*` does not catch the bare namespace: a topic and its children
are different things, and a subscriber that wants both lists both.

## Envelope

`{ id, topic, ts_ms, source, schema, schema_version, payload, trace }`
([`event.rs`](../rust/wa-bus/src/event.rs)). `id` and `ts_ms` are stamped by the bus when unset (a
caller re-publishing a retained event keeps both). `source` is set by the **host**, never by a guest:
it is also what the access policy checks. `payload` is opaque bytes — the bus never parses, logs or
shares them; each subscriber gets its own copy. `Event::summary()` is the log shape: identity and
length only, never payload text.

The durable form is a versioned binary record (`WABUS1` + format byte) with every length checked on
read: a truncated or corrupt record is an error, never a silently short event.

## Delivery

Per subscriber: a bounded FIFO buffer and an explicit overflow policy.

| policy | on a full buffer | for |
| --- | --- | --- |
| `drop_oldest` (default) | discard the oldest queued event, count it | latest-state and logging consumers: lose history, never the present |
| `drop_newest` | refuse the new event, count it | batch consumers that would rather be complete on an old snapshot |
| `block` | refuse it, report it — the publisher waits (`publish_blocking`) or is told `blocked` and retries | critical subscribers: index, audit |

`PublishOutcome { id, matched, delivered, dropped, blocked }` is returned to the producer, so
`dropped > 0` or a non-empty `blocked` is visible at the point of the decision. Nothing is dropped
quietly: the counter lives on the subscription too (`Subscription::dropped`/`blocked`, surfaced by
`Bus::subscriptions()` for `status`).

**Ordering** is FIFO per subscriber, hence per topic per subscriber, including across a `block` wait.
There is no ordering promise *between* topics.

## Revocation

A `Subscription` **is** the registration: dropping the handle unsubscribes (RAII), `close()` says it
explicitly, and `Bus::revoke_owner("wa-whatsapp")` closes every handle an owner holds — the kernel
rule for revocable registrations, so a stopped or replaced component cannot be handed one more event.
`revoke_all()` is node shutdown. After revocation the handle yields nothing (`recv` → `None`,
`is_closed()` → true) and its buffer is gone.

## Durable topics (optional, off by default)

`Bus::enable_durable(topic, retain, kv)` keeps the last N events of one topic through a tiny store —
`get/put/del/scan_prefix`, the same shape as the queue's/`wa:kernel/kv`'s. `MemoryKv` ships for tests
and for a node with no store.

Keys are `v1/<topic>/<ts_ms:020>/<id:020>`, so lexicographic order is time order *across a restart*
and `scan_prefix("v1/<topic>/")` is the topic's whole retained log. `Bus::retained(topic, limit)` and
`Bus::subscribe_replaying(owner, topic, options, limit)` fill a new subscription with the newest
retained events (up to `min(limit, capacity)` — the buffer is filled, drain it before relying on live
delivery). Catch-up is at-least-once over the retention window: a consumer that may have seen an
event before a restart dedupes on `Event::id`.

Retention is written and trimmed **under the bus lock** on publish. That is a deliberate trade — a
reader never sees a half-trimmed log and two publishers cannot delete each other's newest record — and
it is only acceptable because retention is small (N ≤ ~1024) and the store is local. A deployment that
needs an fsync per event wants a queue, not a bus.

## Access control

Default: **own namespace only, everything else denied**, at both doors, and a denial is an error the
caller sees (`bus_publish_denied:<component>:<topic>`), never a silent no-op.

- publish: allowed if `topic.namespace() == event.source`, or a `publish` grant matches the topic.
- subscribe: allowed if the whole pattern is inside the owner's namespace (`wa-whatsapp`,
  `wa-whatsapp.transcript`, `wa-whatsapp.transcript.*`), or a `subscribe` grant **covers** it.

A grant is checked as a set, so `whatsapp.*` authorises `whatsapp.transcript.*` (narrower) and refuses
`*` (wider), and a subscribe grant never implies a publish grant. The hook is the `Access` trait; the
default implementation is `NamespaceAcl`, and a host that keeps grants elsewhere implements `Access`
itself (`AllowAll`/`DenyAll` exist for tests and for a bus that is not the trust boundary).

Manifest shape this maps to (new capability, same model as `net`/`storage`):

```json
{"bus": {"publish": ["whatsapp.transcript.ready"], "subscribe": ["whatsapp.*", "agent.*"]}}
```

The host refuses a grant the manifest did not declare, exactly as it does for `net` addresses.

## WIT draft: `wa:bus`, WASI 0.3

[`wit/bus/bus.wit`](../wit/bus/bus.wit). Two things change with native async:

- **`publish` is `async func`**. Backpressure stops being a policy question at the ABI: a `block`
  subscriber suspends the *task*, the runtime keeps running other tasks, and the future resolves when
  the event is in the buffer. The report still carries `dropped`, so the guest sees an overflow
  instead of inferring it.
- **A subscription is a `stream<event>`**, not a handle + `poll`. Dropping the stream unsubscribes;
  the kernel revokes it when the component stops or is replaced. `replay: option<u32>` asks for
  retained events first, so catch-up is the same call as subscribe.
- `error.again` is the pre-0.3 escape hatch (a host that cannot suspend answers `again` and the guest
  retries), so the same interface survives a preview-2 runtime.

## API (`rust/wa-bus`, no wasmtime, no dependencies)

```rust
let bus = Bus::new();                                   // NamespaceAcl by default
let sub = bus.subscribe("index", "whatsapp.*", SubscribeOptions::new().with_capacity(256))?;
let e = Event::parse("whatsapp.transcript.ready", "whatsapp", "wa.transcript", bytes)?;
let report = bus.publish(e)?;                           // publish_blocking(e, timeout) waits
for event in sub.drain(0) { /* … */ }                    // recv() for one, drain(max) for a page
bus.enable_durable("whatsapp.transcript.ready", 32, Arc::new(MemoryKv::new()))?;
let late = bus.subscribe_replaying("agent", "whatsapp.transcript.ready", opts, 32)?;
bus.revoke_owner("wa-whatsapp");                         // component stopped
```

`Bus` is `Clone` (shares one bus). `Subscription` is a handle: `!Clone`, `Send`, drops = unsubscribe.
One mutex and one condvar for the whole bus: the code stays small enough to audit, and the fan-out
cost is a `VecDeque` push per subscriber.

## Tests (`cargo test -p wa-bus`, 31 + 1 doc test)

Wildcard matching (both directions: `matches` and `covers`), topic validation, envelope round trip and
corruption, summary leaks no payload, fan-out to exact/prefix/all, per-topic ordering across
interleaved publishes, monotonic ids and a caller id that is never re-issued, all three overflow
policies (including a `block` producer that really waits for a consumer on another thread and a
deadline that gives up without dropping), revocation on owner stop, drop-handle unsubscribes,
`revoke_all`, ACL (own namespace, deny by default, grants, narrower-vs-wider, a custom `Access` impl,
policy replaced at runtime), durable catch-up, retention across a bus restart, catch-up refused where
it cannot be honoured.

## Integration into wa-host (built, with the remaining gaps named)

The upgrade landed (wasmtime 50, `component-model-async`), and items 1-4 below are in
`rust/wa-kernel-runtime/src/bus_host.rs`; 5 and 6 are partly done, and item 6's `scripts/fast.sh` half is still
open because that file was out of scope for this change.

* What one subscription costs: one pump thread per subscription (`wa-bus-<owner>`) polling its
  `wa_bus::Subscription` every 5 ms and handing events to the guest's `stream<event>` through a
  bounded queue plus a wake edge. It is honest for the numbers this node runs (a handful of
  long-lived subscribers) and it is the part to replace first if a node ever needs hundreds.
* `unsubscribe` is gone from the WIT: dropping the stream stops the producer, which stops the pump,
  which drops the `wa_bus::Subscription` - the library's RAII rule, kept at the ABI. `services::stop`
  additionally calls `revoke_owner`, so a stopped component's subscriptions end even if its stream
  never dropped.
* `publish` is `async` in the WIT but the host answers locally: a `block` subscriber that is full is
  reported as a refusal (`again` in the draft's vocabulary) instead of suspending the guest task.
  Suspending would need the library to hand out a wake edge per subscription; that is the next step
  if `block` is used for a critical consumer.
* The bus facts this change adds: `kernel.queue.alert` (schema `wa.queue.alert`), published by the
  queue sweeper, last 64 retained in the node's own `kernel.state` retention namespace.

1. **One bus per node**, created in `serve` and owned like the other registries; `Bus::clone()` into
   each component runner. `revoke_owner(component)` from the same place that revokes tools/routes on
   stop, so a stop is exact.
2. **Capability** (`host.bus` for Lua now, `wa:bus` for components later): `publish` / `subscribe` /
   `status`; owner id = the component name from the manifest, `source` set by the host, never by the
   guest. ACL from the `bus` manifest grant, refused at instantiation like `net`.
3. **Delivery to a guest**: before WASI 0.3, a subscription needs a host-side pump (`recv_timeout`
   on the buffer → the guest's `poll`/import); after 0.3, the pump writes into the component's
   `stream<event>` and honours the stream's credit, which is what makes `block` real at the ABI.
4. **Producers to move first**: `wa-whatsapp` (`whatsapp.transcript.ready`, `whatsapp.message`), the
   job/event sources (`inbox.message` today), and the logger. The graph indexer and the agent are the
   first consumers.
5. **Retention via `wa:kernel/kv`** in the component's own namespace, or a host-side store keyed by
   topic; `MemoryKv` is the fallback for a node without storage.
6. **`scripts/fast.sh`** lists crates by hand (`wa-host wa-operation wa-jobs wa-graph wa-sentinel`);
   add `wa-bus` there and to `scripts/test.sh`'s gate so these tests run on landing and nightly. That
   file was out of scope for this change.

## Risks and open questions

- **Payload copies.** Fan-out copies the payload per subscriber (the WIT contract says so). At
  transcript sizes (KBs, low rate) that is cheap; at media sizes it is not. Measure before routing
  audio through the bus; a shared `resource` buffer would be the fix, and it costs the isolation
  story.
- **Retention under the lock.** See above: small N, local store. Not measured against a real
  `wa:kernel/kv` yet.
- **At-least-once catch-up.** Dedupe on `Event::id` is the consumer's job; the bus does not keep a
  per-subscriber cursor (that would make it a queue).
- **Cross-node fan-out** is not in scope: that is the relay's job, and it must not be faked here.
- **Stream credit** semantics on WASI 0.3 (`block` + a slow guest) are unverified until a host exists.

## Non-goals

Exactly-once, claims/acks, replay beyond the retention window, cross-node delivery, payload schemas
enforced by the bus (only *named*: `schema` + `schema_version`), and per-topic global ordering.
