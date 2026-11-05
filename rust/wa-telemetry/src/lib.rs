//! Fixed-size per-component telemetry: metrics, rollups and sampled traces.
//!
//! Three promises, in the order they matter:
//!
//! 1. **Storage is bounded by design.** Counters/gauges/histograms have capped cardinality (a label
//!    set past the cap folds into one `wa_other` series and is counted), rollups live in fixed rings
//!    (per minute for a day, per hour for a month, per day for ten years), and traces live in a
//!    byte-capped ring with oldest-first eviction. No file grows with traffic.
//! 2. **Nothing is silently lost.** Overflow, refusals, sampled-away spans, evicted spans, truncated
//!    attributes and unknown queue latencies are all counters an operator can read.
//! 3. **It is a library.** No wasmtime, no threads of its own, no network, no clock of its own: the
//!    host passes a [`Clock`], calls [`Metrics::tick`] on a timer and decides where
//!    [`Metrics::prometheus`] / [`Metrics::to_json`] go.
//!
//! ```no_run
//! use std::sync::Arc;
//! use wa_telemetry::{Config, Metrics, SpanStatus};
//!
//! let metrics = Metrics::new(Config::default());
//! let calls = metrics.counter("wa-kernel", "component_call_total");
//! calls.add_labeled(1, &[("component", "wa-whatsapp"), ("status", "ok")]);
//!
//! let started = metrics.now_ms();
//! metrics.record_op("wa-whatsapp", "transcribe", started, 84_000, SpanStatus::Ok);
//! metrics.tick();
//! let text = metrics.prometheus();
//! # let _ = text;
//! ```
//!
//! Design notes and the recording points the host owns: `docs/TELEMETRY.md`.
pub mod clock;
pub mod export;
pub mod histogram;
pub mod labels;
pub mod queue;
pub mod rollup;
mod config;
mod metrics;
mod snapshot;
mod trace;

pub use clock::{manual, Clock, ManualClock, SystemClock};
pub use config::Config;
pub use labels::Labels;
pub use metrics::{
    Counter, Gauge, Histogram, HistogramView, Kind, Metrics, SpanTimer, TelemetryStats, TraceStats,
};
pub use queue::QueueMetrics;
pub use rollup::{RollupPoint, RollupSeriesView, Level3};
pub use snapshot::SnapshotError;
pub use trace::{Keep, Sampler, Span, SpanStatus};

/// Default bounds, for an operator who wants to see them without opening the source.
pub fn default_caps() -> Config {
    Config::default()
}

#[cfg(test)]
mod tests;
