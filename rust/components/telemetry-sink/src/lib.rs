//! The telemetry sink component: a subscriber that hears facts, decodes the typed frame a producer
//! published, and hands the batch to the node's sink.
//!
//! What it owns: the subscription, the decode, the mapping to `wa:telemetry` records, and its own
//! counters. What it deliberately does **not** own:
//!
//! * the buffer — the node's bounded, drop-oldest ring is the back-pressure (`telemetry_dropped`),
//!   and the guest cannot grow it;
//! * the file — rotating JSONL is the host's, so a guest cannot name a path or hold a handle;
//! * the network — the OTLP edge is the host's, behind one granted endpoint;
//! * the payload text — a decode failure is counted and the *bytes are never logged*, and a record
//!   has no text field to begin with (`wa_telemetry_sink::record`).
//!
//! The loop is one `await` on the bus stream. A frame is one batch: the producer batched its facts, so
//! the sink does not add a timer that would hold the last record of a quiet node until the next event
//! (that is the classic batcher bug). A frame larger than `max_batch` is split.
//!
//! Per `wa:kernel@0.2` (WASI 0.3) nothing polls: `subscribe` returns a `stream<event>`, `next().await`
//! suspends the guest task, and dropping the stream (the supervisor revoking the component, or the
//! stream ending) unsubscribes.
//!
//! Proof: `cargo build --target wasm32-wasip2` builds it, `scripts/test-telemetry-sink-component.sh`
//! builds it and checks the manifest's grants, and the host half is tested in `rust/wa-telemetry-sink`.
wit_bindgen::generate!({ path: "wit", world: "component", generate_all });

use wa::bus::subscriber;
use wa::bus::types::{Overflow, SubscriptionOptions};
use wa::kernel::{lifecycle, log};
use wa::telemetry::sink as host_sink;
use wa::telemetry::types as tel;
use wa_telemetry_sink::codec;
use wa_telemetry_sink::record::{
    AttrValue, Id, MetricKind, MetricRecord, Record, Severity, SpanRecord, SpanStatus, TraceId, Unit,
};

/// The subscription the manifest grants (`capabilities.bus.subscribe = ["*"]`). A telemetry sink is
/// the one component for which "everything" is the honest grant: it publishes nothing, so it cannot
/// forge a fact, and the bus is already node-local.
const PATTERN: &str = "*";
/// Events buffered by the bus for this subscriber. The bus's own overflow policy is drop-oldest, so a
/// slow sink costs the oldest fact and the bus counts it — the same contract the sink's buffer has.
const SUBSCRIPTION_CAPACITY: u32 = 1_024;
/// Records per `submit` call when a producer's frame carries more.
const DEFAULT_MAX_BATCH: usize = 64;
/// Log a progress line every this many records, so a quiet node stays quiet.
const PROGRESS_EVERY: u64 = 10_000;

struct Service;

impl exports::wa::kernel::service::Guest for Service {
    async fn run(config: String) -> Result<(), String> {
        // The kernel hands the definition's `config` object as JSON text. It carries counts and
        // switches only: a pattern, a batch size. Nothing here reads the sink's own configuration
        // (endpoint, directory): that is the node's, granted by the manifest and the operator.
        let config: serde_json::Value = serde_json::from_str(&config).unwrap_or_default();
        let max_batch = config["max_batch"].as_u64().unwrap_or(DEFAULT_MAX_BATCH as u64).clamp(1, 4_096) as usize;

        lifecycle::report(lifecycle::Health::Starting, None);
        let mut events = match subscriber::subscribe(
            PATTERN,
            SubscriptionOptions { capacity: SUBSCRIPTION_CAPACITY, overflow: Overflow::DropOldest },
            None,
        ) {
            Ok(stream) => stream,
            Err(error) => {
                line(&format!("subscribe failed {error:?}"));
                lifecycle::report(lifecycle::Health::Degraded, Some("bus_refused"));
                return Err(format!("subscribe: {error:?}"));
            }
        };
        lifecycle::report(lifecycle::Health::Ready, None);
        line("ready");

        let mut counters = SinkGuestStats::default();
        loop {
            if lifecycle::stopping() {
                break;
            }
            // The subscription is the loop: a revoke ends the stream, a stop is also seen here.
            let Some(event) = events.next().await else {
                line("stream ended (subscription revoked)");
                break;
            };
            match codec::decode(&event.payload) {
                Ok(records) => {
                    for chunk in records.chunks(max_batch) {
                        let batch = tel::Batch { records: chunk.iter().map(to_wit).collect() };
                        let size = batch.records.len() as u64;
                        counters.decoded += size;
                        match host_sink::submit(batch).await {
                            Ok(report) => {
                                counters.submitted += size;
                                counters.host_dropped += u64::from(report.dropped);
                                counters.batches += 1;
                                if counters.submitted >= counters.next_progress {
                                    counters.next_progress = counters.submitted + PROGRESS_EVERY;
                                    line(&format!(
                                        "submitted={} batches={} host_dropped={} decode_failures={}",
                                        counters.submitted, counters.batches, counters.host_dropped, counters.decode_failures
                                    ));
                                }
                            }
                            Err(error) => {
                                counters.submit_failures += 1;
                                // Rate-limited: a closed sink must not turn into a log storm.
                                if counters.submit_failures <= 5 || counters.submit_failures % 1_000 == 0 {
                                    line(&format!("submit failed {} ({})", describe(&error), counters.submit_failures));
                                }
                                if matches!(error, tel::Error::Closed) {
                                    lifecycle::report(lifecycle::Health::Degraded, Some("sink_closed"));
                                    break;
                                }
                            }
                        }
                    }
                }
                Err(error) => {
                    // The bytes are never logged: an unrecognised payload is the one place message text
                    // could otherwise reach a log through this component.
                    counters.decode_failures += 1;
                    if counters.decode_failures <= 5 || counters.decode_failures % 1_000 == 0 {
                        line(&format!("dropped frame: {error} ({})", counters.decode_failures));
                    }
                }
            }
        }

        {
            let stats = host_sink::counters();
            line(&format!(
                "stopping submitted={} batches={} host_dropped={} decode_failures={} submit_failures={} sink(status dropped={} exported={} jsonl_rows={} otlp_sent={} otlp_failed={})",
                counters.submitted,
                counters.batches,
                counters.host_dropped,
                counters.decode_failures,
                counters.submit_failures,
                stats.telemetry_dropped,
                stats.exported,
                stats.jsonl_rows,
                stats.otlp_sent,
                stats.otlp_failed
            ));
        }
        Ok(())
    }
}

#[derive(Default)]
struct SinkGuestStats {
    decoded: u64,
    submitted: u64,
    batches: u64,
    host_dropped: u64,
    decode_failures: u64,
    submit_failures: u64,
    next_progress: u64,
}

fn describe(error: &tel::Error) -> String {
    match error {
        tel::Error::Refused(reason) => format!("refused: {reason}"),
        tel::Error::Again => "again".to_string(),
        tel::Error::Closed => "closed".to_string(),
        tel::Error::Failed(reason) => format!("failed: {reason}"),
    }
}

/// One line to the component's log, through the kernel (the same file stdout goes to).
fn line(text: &str) {
    log::write(log::Level::Info, "telemetry-sink", text);
    println!("{text}");
}

// --- the record mapping -------------------------------------------------------------------------
//
// The host and the guest share `wa_telemetry_sink::record` (the frame), but the WIT boundary is typed,
// so each field crosses as itself: no JSON, no string-encoded struct.

fn to_wit(record: &Record) -> tel::Item {
    match record {
        Record::Span(span) => tel::Item::Span(span_wit(span)),
        Record::Metric(metric) => tel::Item::Metric(metric_wit(metric)),
        Record::Event(event) => tel::Item::Event(tel::Event {
            topic: event.topic.as_str().to_string(),
            source: event.source.as_str().to_string(),
            schema: event.schema.as_str().to_string(),
            schema_version: event.schema_version,
            ts_ms: event.ts_ms,
            count: event.count,
            severity: severity_wit(event.severity),
            trace: event.trace.map(TraceId::to_hex),
            attrs: attrs_wit(&event.attrs),
        }),
    }
}

fn span_wit(span: &SpanRecord) -> tel::Span {
    tel::Span {
        component: span.component.as_str().to_string(),
        op: span.op.as_str().to_string(),
        start_ms: span.start_ms,
        duration_us: span.duration_us,
        status: status_wit(span.status),
        trace: span.trace.map(TraceId::to_hex),
        attrs: attrs_wit(&span.attrs),
    }
}

fn metric_wit(metric: &MetricRecord) -> tel::Metric {
    tel::Metric {
        component: metric.component.as_str().to_string(),
        name: metric.name.as_str().to_string(),
        kind: match metric.kind {
            MetricKind::Counter => tel::MetricKind::Counter,
            MetricKind::Gauge => tel::MetricKind::Gauge,
        },
        unit: match metric.unit {
            Unit::Count => tel::Unit::Count,
            Unit::Micros => tel::Unit::Microseconds,
            Unit::Millis => tel::Unit::Milliseconds,
            Unit::Bytes => tel::Unit::Bytes,
            Unit::Ratio => tel::Unit::Ratio,
        },
        value: metric.value,
        labels: attrs_wit(&metric.labels),
    }
}

fn status_wit(status: SpanStatus) -> tel::Status {
    match status {
        SpanStatus::Ok => tel::Status::Ok,
        SpanStatus::Error => tel::Status::Error,
        SpanStatus::Expired => tel::Status::Expired,
        SpanStatus::Cancelled => tel::Status::Cancelled,
    }
}

fn severity_wit(severity: Severity) -> tel::Severity {
    match severity {
        Severity::Trace => tel::Severity::Trace,
        Severity::Debug => tel::Severity::Debug,
        Severity::Info => tel::Severity::Info,
        Severity::Warn => tel::Severity::Warn,
        Severity::Error => tel::Severity::Error,
        Severity::Critical => tel::Severity::Critical,
    }
}

fn attrs_wit(attrs: &wa_telemetry_sink::Attrs) -> Vec<tel::Attr> {
    attrs
        .iter()
        .map(|attr| tel::Attr {
            key: attr.key.as_str().to_string(),
            value: match &attr.value {
                AttrValue::Id(id) => tel::AttrValue::Id(id.as_str().to_string()),
                AttrValue::Count(value) => tel::AttrValue::Count(*value),
                AttrValue::Digest { len, hash } => tel::AttrValue::Digest(tel::Digest { len: *len, hash: *hash }),
                AttrValue::Redacted => tel::AttrValue::Redacted,
            },
        })
        .collect()
}

/// Keeps the `Id` import meaningful to the compiler in a build where every field is inlined above; the
/// component's own ids are the same validated names the host uses, so this is a compile-time contract
/// rather than an unused import.
const _: fn(&Id) = |_id| ();

export!(Service);
