# telemetry — bounded per-component metrics, rollups and sampled traces

Status 2026-11-06: crate `rust/wa-telemetry` implemented and tested (34 unit tests); **not yet wired
into `wa-host`**. This document is the design and the contract. Nothing here is claimed as measured
on a live node.

Related: [OBSERVABILITY.md](OBSERVABILITY.md) (the `harness_events` ledger for engineering runs —
a different, append-only store), [KERNEL.md](KERNEL.md) and
[SERVICE-COMPONENTS.md](SERVICE-COMPONENTS.md) (where components come from),
[WHATSAPP-TRANSCRIPTION.md](WHATSAPP-TRANSCRIPTION.md) (the transcription path whose B3 cutover this
has to be able to read).

## The problem

A node runs for weeks. Anything that stores one row per call fills the disk; anything that keeps a
label value per chat, per message or per file destroys the scrape with cardinality. Both failures are
silent until the disk or the process dies.

So storage is bounded **by construction**, and every bound that is hit is a counter:

| tier | what it holds | how it stays fixed |
| --- | --- | --- |
| live series | counters, gauges, latency histograms | capped label sets; overflow folds into one `wa_other` series |
| rollups | per minute for 24 h, per hour for 30 d, per day for 10 y | ring arrays sized from `Config`, allocated once |
| traces | spans with op, duration, status, capped attrs | byte-capped ring, oldest-first eviction (200 MiB default) |

There is no compaction job, no rotation, no file that grows with traffic, and no background thread.
The host calls `tick()` (roll over the clock) and `save()` (snapshot) when it wants to.

## Registry

`Metrics` (one per node) → component → metric family (`counter`/`gauge`/`histogram`) → series (a label
set). A handle (`Counter`, `Gauge`, `Histogram`) is cheap to clone and records into shared state.

- **Names**: metric names are `[A-Za-z0-9_]`, truncated to `max_name_len`. A component name is a
  *label value*: it keeps its dashes (`wa-whatsapp`), only its length is bounded.
- **Labels**: at most `max_labels` pairs, sorted, keys ≤32 B, values ≤64 B, first duplicate key wins.
  Order does not matter: `[("b","2"),("a","1")]` and `[("a","1"),("b","2")]` are one series.
- **Cardinality**: past `max_series_per_family` the observation is folded into one series labelled
  `wa_other="1"` and the family's folded count rises. `wa_telemetry_cardinality_dropped` is exported
  for every such family, so a component that invents a label value per message is visible as a
  growing count, not as memory.
- **Refusals are counters**: `wa_telemetry_refused_total{reason="component"|"family"|"rollup"}`.
- **A name is one kind**: using `queue_depth` first as a gauge then as a counter is refused and
  counted (`wa_telemetry_kind_conflicts_total`); the export keeps one `# TYPE` line per name.

### Latency histograms

Values are microseconds on a fixed log bucket array (HDR's idea, not the crate): buckets
`0..2^sub_bits` are exact, above that each power of two is split into `2^sub_bits` buckets, so the
relative error is at most `1/2^(sub_bits+1)` — 3.1% at the default 4. The array is
`(64 - sub_bits) << sub_bits` = 976 counters, ~7.8 KiB per series, allocated once.

`p50`/`p95` interpolate inside the bucket the rank lands in. That is an **estimate with a known
bound** (one bucket width), not an order statistic, and the docs say so wherever it is read.

## Rollups

An hour is the sum of the minutes it holds; a day is the sum of its hours. A query over 24 h reads
1440 slots, never the raw observations.

- Keys are absolute bucket indices (`now_ms / 60_000`, `/ 3_600_000`, `/ 86_400_000`) stored with
  the slot, so a ring wrap is detected instead of trusted and a clock step cannot mislabel a bucket.
- `tick()` closes every bucket the clock has left. Buckets with no observations are never written
  (sparse by design), so an idle component costs nothing.
- A cell carries `observations`, `errors`, `sum`, `min`, `max` and `last`. Counts and min/max
  saturate at `u32` (a single observation over ~71 minutes of µs saturates rather than wraps); `sum`
  is `u64`. For a counter the "value" is the delta recorded in that bucket, for a gauge it is the
  written value and `last` is the last one (a negative gauge value clamps to 0 in the bucket's
  `min`/`max`/`sum`; `last` keeps the sign, and the live gauge keeps the exact value).

## Traces

A span is `{trace_id, component, op, start_ms, duration_us, status, attrs}`. Status is `ok`, `error`,
`expired` or `cancelled`.

The sampler, in order: an **error is always kept**; a span slower than its op's threshold
(`trace_slow_by_op`, key `component/op`, then `component/*`, then `trace_slow_us`) is **always kept**;
otherwise it is kept by a hash of `(component, op, trace_id)` modulo 1000 below
`trace_sample_permille` (default 20 = 2%). The hash makes the decision a property of the span, so a
2% sample is reproducible across restarts and nodes.

The ring stores **encoded blobs**, not structs: the byte cap is exact, eviction is one pop from the
front, and a span larger than the whole ring is refused and counted
(`wa_telemetry_trace_total{field="oversized"}`). Attrs are capped at `max_span_attrs` pairs with
truncated keys/values; dropped pairs and truncated values are counted, never silently edited away.

A span never registers a metric series: 5000 different op names create 5000 spans at most, and one
counter with one label set.

## Queue lifecycle

`QueueMetrics::new(metrics, component, queue)` gives the five moments of a job: `enqueued(id, job)`,
`started`, `done`, `failed(reason)`, `expired(reason)`. The caller owns the queue; this layer only
names the numbers:

| metric | meaning |
| --- | --- |
| `queue_enqueued_total{queue,job}` | accepted |
| `queue_started_total`, `queue_done_total` | started, finished ok |
| `queue_wait_micros{queue,job}` | enqueue → start (histogram) |
| `queue_run_micros{queue,job}` | start → done/failed (histogram) |
| `queue_failed_total{queue,job,reason}` | failed, `reason` from a closed set |
| `queue_expired_total{queue,job,reason}` | never ran: freshness window, TTL |
| `queue_expired_age_micros` | enqueue (or start, when it did start) → expiry |
| `queue_pending{queue}` | tracked now |
| `queue_latency_unknown_total{queue,job}` | latency not measurable (untracked or never started) |

Tracking is bounded to 1024 ids. A job beyond that still counts, but its latency is **unknown**, and
`queue_latency_unknown_total` says so instead of reporting a zero. `reason` is a label, so it must be
a small closed set: never a message, never an error text with a path or an id in it.

## Default caps

`Config::default()`; every value is a knob, and `Config::for_tests()` is the small one the tests use.

| cap | default | cost when full |
| --- | --- | --- |
| `max_components` | 256 | `reason="component"` |
| `max_families_per_component` | 512 | `reason="family"` |
| `max_series_per_family` | 32 (+1 overflow) | folded into `wa_other`, counted |
| `hist_sub_bits` | 4 | 976 × u64 ≈ 7.8 KiB per histogram series |
| `rollup_series` | 64 | `reason="rollup"`; 227 KiB per series with the rings below |
| `minute_slots` / `hour_slots` / `day_slots` | 1440 / 720 / 3653 | ≈ 56 + 28 + 143 KiB per series (40 B slot) |
| `trace_bytes` | 200 MiB | oldest-first eviction, counted |
| `trace_sample_permille` | 20 (2%) | — |
| `trace_slow_us` | 500 ms | — |
| `max_span_attrs` / `max_attr_key` / `max_attr_value` | 8 / 32 B / 64 B | counted |
| `max_labels` / `max_label_key` / `max_label_value` | 4 / 32 B / 64 B | folds into `wa_other` |

Worst case with all defaults is 14.9 MiB of rollups (64 series × 227 KiB) plus the 200 MiB trace
ring plus the live histograms. That is the whole point: it does not depend on how many calls or chats a node saw.

## Where the host records (planned; the host is not edited here)

The crate is a library and the host owns the call sites. What belongs where:

| point | what | names |
| --- | --- | --- |
| every component call | one span + latency + outcome, from a single call: `record_op(component, op, start_ms, duration_us, status)` | `op_duration_micros{op}`, `op_total{op,status}` |
| every host call (`host.*` capability) | the same, attributed to the capability not the caller: `record_op("wa-kernel", capability, …)` or, for the caller's view, a histogram on the calling component | `host_call_duration_micros{capability}`, `host_call_total{capability,status}` |
| service health | a gauge per service instance: 1 running, 0 stopped; a counter per restart reason | `service_health{service,instance}`, `service_restart_total{service,reason}` |
| queue events | `QueueMetrics` per (component, queue) | `queue_*` above |
| clock | `tick()` once a second from the node loop (cheap when nothing happened) | — |
| snapshot | `save(path)` on a timer (atomic: temp + fsync + rename) | — |
| operator view | `prometheus()` and `to_json()`; `rollups_json()` and `traces_json()` on demand | — |

Not in the crate, on purpose: where the state file lives, how often it is written, whether a service
gets its own registry, and any HTTP. No exporter, no client, no network — the host decides.

## Reading the B3 cutover

The transcription stream's question is "is a voice note transcribed in time, and what does a late one
look like". With the host wiring above, the reads are:

- **Latency p50/p95** — `histogram("wa-whatsapp", "op_duration_micros").get(&[("op","transcribe")])`
  returns `{count, sum, min, max, mean, p50, p95}`; in the Prometheus text the same numbers are the
  cumulative `_bucket{le=…}`, `_sum` and `_count` lines. Percentiles are bucket-bounded (±3% relative
  at the default resolution), always with `count` beside them, because a p95 over 4 samples is noise.
- **Failures** — `queue_failed_total{job="transcribe",reason}` (reason is the closed set the caller
  passes: decode/unsupported/missing-media/…) and `op_total{op="transcribe",status="error"}`.
- **Expiries** — `queue_expired_total{job="transcribe",reason="stale_over_5m"}` and
  `queue_expired_age_micros`, which is how long the audio waited before it was given up on; the
  5-minute window in [WHATSAPP-TRANSCRIPTION.md](WHATSAPP-TRANSCRIPTION.md) should show as a cluster
  of ages just under it, and anything above it is a bug worth reading the ring for.
- **Trend** — `rollups_json()` / `Metrics::rollups()` for the same series: `minutes` for the last 24 h
  (1440 slots), `hours` for the last 30 d, `days` for ten years, each with `observations`, `errors`,
  `sum`, `min`, `max`. A cutover is "p95 down, expiries to zero, error count flat", read at two
  resolutions rather than from two different tools.
- **The span behind a number** — `traces_json()` filtered by `component == "wa-whatsapp"` and
  `op == "transcribe"`: every error and every span over the threshold is there by the sampling rule,
  plus ~2% of the normal ones.

## What it deliberately does not do

- Keep message text, transcripts, file paths or secrets. A span carries op names and capped attrs;
  `reason` labels are closed sets. If a value is needed for diagnosis it goes in the ledger
  ([OBSERVABILITY.md](OBSERVABILITY.md)) with its redaction rules, not here.
- Grow with traffic. When a cap is hit the count goes up, not the memory.
- Expose a metrics HTTP endpoint. `prometheus()` is a string; whoever serves it is elsewhere.
- Claim precision it does not have: percentiles are bucket estimates, gauges are last-write-wins,
  queue latencies that could not be tracked are counted as unknown rather than as zero.

## Open questions

- One registry per node or one per service component? Per node keeps `-` in names and makes one
  snapshot; per component gives independent deadlines and no shared lock.
- Persistence cadence and retention outside the process (a snapshot file per node restarts at boot:
  is "restore on start" wanted, or does a node start clean?).
- After the WASI 0.3 / wasmtime 50 upgrade: whether each component instance gets its own registry so a
  component's metrics die with the instance (that is the natural fit for store-per-instance) or the
  store is global and `instance` becomes a label.
