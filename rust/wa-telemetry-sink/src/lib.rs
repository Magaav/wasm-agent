//! The telemetry sink: telemetry leaves the node off the hot path, as typed records, and only becomes
//! text at the export edge.
//!
//! Today telemetry is collected in-node (`rust/wa-telemetry` plus `wa-host/src/node_telemetry.rs`):
//! a registry with fixed caps, ticked and snapshotted by the host. That is the *live* view. This crate
//! is the *outbound* view: a component subscribes to `wa:bus`, batches spans/metrics/events, and the
//! sink writes them to a local rotating JSONL file (default, human-readable — this is where JSON
//! belongs) and, when an operator grants it, POSTs OTLP/HTTP JSON to one configured collector.
//!
//! ## The four promises
//!
//! 1. **The producer never waits.** [`Sink::record`] takes one mutex, evicts if the budget is full and
//!    returns. No file, no socket, no thread, no allocation beyond the record the caller already owns.
//!    A dead collector and a slow disk are invisible to the code being measured.
//! 2. **Bounded, and every bound that is hit is a counter.** The buffer is bounded in records and in
//!    *encoded* bytes ([`buffer::Bounds`]); overflow drops the oldest record and increments
//!    `telemetry_dropped` ([`stats::SinkStats::telemetry_dropped`]). The JSONL directory is bounded
//!    by `max_bytes × max_files`. Nothing here grows with traffic.
//! 3. **No message text, ever.** A [`record::Record`] has no text field: attributes are ids, counts or
//!    a digest ([`record::Attr::from_text`]), and anything secret-shaped is dropped with the rules
//!    `lua/core/redact.lua` already uses ([`redact`]). The bus frame carries names only and the
//!    decoder refuses a frame that tries to carry anything else ([`codec::decode`]).
//! 4. **It is a library.** No thread of its own, no timer, no socket except the optional exporter's
//!    one POST, and no JSON on the bus: the same rule `wa-telemetry` follows, for the same reason.
//!
//! ## Shape
//!
//! ```text
//! producer ──Record──▶ Ring (bounded, drop-oldest, telemetry_dropped)
//!                              │  pump()  ── the node's existing tick, or an exporter task
//!                              ├──▶ JSONL writer (rotating, bounded directory)      [always]
//!                              └──▶ OTLP/HTTP JSON (one granted host, best effort)   [optional]
//! ```
//!
//! ```no_run
//! use wa_telemetry_sink::{record::{Record, SpanStatus}, sink::{Config, Sink}};
//!
//! # fn main() -> std::io::Result<()> {
//! let sink: Sink = Sink::open(Config::default().with_jsonl("data/telemetry"))?;
//! // Producer side: bounded work, no I/O.
//! sink.record(Record::span("wa-whatsapp", "transcribe", 1_700_000_000_000, 84_000, SpanStatus::Ok));
//! // Exporter side: whoever owns the tick calls this. A slow collector cannot reach the producer.
//! sink.pump();
//! println!("dropped so far: {}", sink.stats().telemetry_dropped);
//! # Ok(())
//! # }
//! ```
//!
//! ## What leaves this crate
//!
//! * [`sink::Sink`] and [`sink::Config`] — what the host owns one of.
//! * [`record`] + [`codec`] — what the sink component speaks (`rust/components/telemetry-sink`), also
//!   compiled without the `host` feature so the guest cannot open a file or a socket.
//! * [`stats::SinkStats`] — the numbers, including the `telemetry_dropped` headline, in Prometheus and
//!   in `host.telemetry` shape.
//! * `docs/OBSERVABILITY.md` (the sink's contract) and `wit/telemetry/telemetry.wit` (the guest's
//!   side of it).
//!
//! Design notes and the recording points: `docs/OBSERVABILITY.md`, "The sink".

pub mod buffer;
pub mod codec;
pub mod hash;
pub mod json;
pub mod record;
pub mod redact;
pub mod stats;

#[cfg(feature = "host")]
pub mod jsonl;
#[cfg(feature = "host")]
pub mod measure;
#[cfg(feature = "host")]
pub mod otlp;
#[cfg(feature = "host")]
pub mod sink;

#[cfg(feature = "host")]
pub use sink::{Config, FlushReport, Sink};
#[cfg(feature = "host")]
pub use jsonl::JsonlConfig;
#[cfg(feature = "host")]
pub use otlp::{OtlpConfig, OtlpExporter, Signal, TcpTransport, Transport};
pub use buffer::Bounds;
pub use record::{Attr, AttrValue, Attrs, EventRecord, Id, MetricKind, MetricRecord, Record, Severity, SpanRecord, SpanStatus, TraceId, Unit};
pub use stats::{Counters, SinkStats};
