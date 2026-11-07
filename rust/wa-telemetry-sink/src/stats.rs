//! The counters the sink publishes. `telemetry_dropped` is one name on purpose: an operator asks one
//! question ("did the sink lose anything?") and gets one number, with the reason broken out beside it
//! instead of hidden.
use std::sync::atomic::{AtomicU64, Ordering};

use crate::record::Record;

#[derive(Debug, Default)]
pub struct Counters {
    accepted: AtomicU64,
    dropped: AtomicU64,
    oversized: AtomicU64,
    exported: AtomicU64,
    exported_batches: AtomicU64,
    jsonl_rows: AtomicU64,
    jsonl_bytes: AtomicU64,
    jsonl_rotations: AtomicU64,
    jsonl_failed: AtomicU64,
    otlp_sent: AtomicU64,
    otlp_failed: AtomicU64,
    otlp_dropped: AtomicU64,
    otlp_recovered: AtomicU64,
    redacted: AtomicU64,
    digested: AtomicU64,
    last_error_ms: AtomicU64,
    error_hits: AtomicU64,
}

impl Counters {
    pub fn new() -> Counters {
        Counters::default()
    }

    fn bump(counter: &AtomicU64, by: u64) {
        counter.fetch_add(by, Ordering::Relaxed);
    }

    pub(crate) fn accepted(&self, by: u64) {
        Self::bump(&self.accepted, by)
    }

    /// `telemetry_dropped`: the one number that says the sink lost something.
    pub(crate) fn dropped(&self, by: u64) {
        Self::bump(&self.dropped, by)
    }

    pub(crate) fn oversized(&self, by: u64) {
        Self::bump(&self.oversized, by)
    }

    // The export side's counters exist only in a host build: the guest (`default-features = false`)
    // holds no file and no socket, so it has no row, byte or batch to count.
    #[cfg(feature = "host")]
    pub(crate) fn exported(&self, by: u64) {
        Self::bump(&self.exported, by)
    }

    #[cfg(feature = "host")]
    pub(crate) fn exported_batches(&self, by: u64) {
        Self::bump(&self.exported_batches, by)
    }

    #[cfg(feature = "host")]
    pub(crate) fn jsonl_rows(&self, by: u64) {
        Self::bump(&self.jsonl_rows, by)
    }

    #[cfg(feature = "host")]
    pub(crate) fn jsonl_bytes(&self, by: u64) {
        Self::bump(&self.jsonl_bytes, by)
    }

    #[cfg(feature = "host")]
    pub(crate) fn jsonl_rotations(&self, by: u64) {
        Self::bump(&self.jsonl_rotations, by)
    }

    #[cfg(feature = "host")]
    pub(crate) fn jsonl_failed(&self, by: u64) {
        Self::bump(&self.jsonl_failed, by)
    }

    #[cfg(feature = "host")]
    pub(crate) fn otlp_sent(&self, by: u64) {
        Self::bump(&self.otlp_sent, by)
    }

    #[cfg(feature = "host")]
    pub(crate) fn otlp_failed(&self, by: u64) {
        Self::bump(&self.otlp_failed, by)
    }

    #[cfg(feature = "host")]
    pub(crate) fn otlp_dropped(&self, by: u64) {
        Self::bump(&self.otlp_dropped, by)
    }

    #[cfg(feature = "host")]
    pub(crate) fn otlp_recovered(&self, by: u64) {
        Self::bump(&self.otlp_recovered, by)
    }

    /// A record arrived carrying at least one value the sink had to mask or digest.
    pub(crate) fn inspect(&self, record: &Record) {
        let mut redacted = 0u64;
        let mut digested = 0u64;
        for attr in record.attrs().iter() {
            match attr.value {
                crate::record::AttrValue::Redacted => redacted += 1,
                crate::record::AttrValue::Digest { .. } => digested += 1,
                _ => {}
            }
        }
        Self::bump(&self.redacted, redacted);
        Self::bump(&self.digested, digested);
    }

    #[cfg(feature = "host")]
    pub(crate) fn failed_at(&self, now_ms: u64) {
        Self::bump(&self.error_hits, 1);
        self.last_error_ms.store(now_ms, Ordering::Relaxed);
    }

    pub fn snapshot(&self) -> SinkStats {
        SinkStats {
            accepted: self.accepted.load(Ordering::Relaxed),
            telemetry_dropped: self.dropped.load(Ordering::Relaxed),
            oversized: self.oversized.load(Ordering::Relaxed),
            exported: self.exported.load(Ordering::Relaxed),
            exported_batches: self.exported_batches.load(Ordering::Relaxed),
            jsonl_rows: self.jsonl_rows.load(Ordering::Relaxed),
            jsonl_bytes: self.jsonl_bytes.load(Ordering::Relaxed),
            jsonl_rotations: self.jsonl_rotations.load(Ordering::Relaxed),
            jsonl_failed: self.jsonl_failed.load(Ordering::Relaxed),
            otlp_sent: self.otlp_sent.load(Ordering::Relaxed),
            otlp_failed: self.otlp_failed.load(Ordering::Relaxed),
            otlp_dropped: self.otlp_dropped.load(Ordering::Relaxed),
            otlp_recovered: self.otlp_recovered.load(Ordering::Relaxed),
            attrs_redacted: self.redacted.load(Ordering::Relaxed),
            attrs_digested: self.digested.load(Ordering::Relaxed),
            last_error_ms: self.last_error_ms.load(Ordering::Relaxed),
            error_hits: self.error_hits.load(Ordering::Relaxed),
        }
    }
}

/// One readable snapshot of the whole sink. `telemetry_dropped` is the headline; everything else is
/// why.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SinkStats {
    pub accepted: u64,
    /// Records the buffer refused or evicted (overflow *and* oversized). Never silently lost.
    pub telemetry_dropped: u64,
    /// Records larger than `max_record_bytes`, refused whole.
    pub oversized: u64,
    pub exported: u64,
    pub exported_batches: u64,
    pub jsonl_rows: u64,
    pub jsonl_bytes: u64,
    pub jsonl_rotations: u64,
    pub jsonl_failed: u64,
    pub otlp_sent: u64,
    pub otlp_failed: u64,
    pub otlp_dropped: u64,
    pub otlp_recovered: u64,
    pub attrs_redacted: u64,
    pub attrs_digested: u64,
    pub last_error_ms: u64,
    pub error_hits: u64,
}

impl SinkStats {
    /// Metrics-shaped view, for the node's registry: the names an operator scrapes, in one place so a
    /// dashboard and the docs cannot drift.
    pub fn prometheus(&self, queued: usize, queued_bytes: usize) -> String {
        let mut out = String::new();
        for (name, help, value) in [
            ("telemetry_sink_accepted_total", "records accepted into the sink buffer", self.accepted),
            ("telemetry_dropped", "records the sink buffer refused or evicted", self.telemetry_dropped),
            ("telemetry_sink_oversized_total", "records refused as larger than the record cap", self.oversized),
            ("telemetry_sink_exported_total", "records handed to the export edges", self.exported),
            ("telemetry_sink_exported_batches_total", "batches flushed", self.exported_batches),
            ("telemetry_sink_jsonl_rows_total", "JSONL rows written", self.jsonl_rows),
            ("telemetry_sink_jsonl_bytes_total", "JSONL bytes written", self.jsonl_bytes),
            ("telemetry_sink_jsonl_rotations_total", "JSONL rotations", self.jsonl_rotations),
            ("telemetry_sink_jsonl_failed_total", "JSONL rows lost to an I/O error", self.jsonl_failed),
            ("telemetry_sink_otlp_sent_total", "OTLP batches the collector accepted", self.otlp_sent),
            ("telemetry_sink_otlp_failed_total", "OTLP batches that failed", self.otlp_failed),
            ("telemetry_sink_otlp_dropped_total", "records not retried after an OTLP failure", self.otlp_dropped),
            ("telemetry_sink_otlp_recovered_total", "batches that succeeded after a failure", self.otlp_recovered),
            ("telemetry_sink_attrs_redacted_total", "attribute values dropped as secret-shaped", self.attrs_redacted),
            ("telemetry_sink_attrs_digested_total", "attribute values reduced to a digest", self.attrs_digested),
            ("telemetry_sink_errors_total", "export errors", self.error_hits),
        ] {
            out.push_str(&format!("# HELP {name} {help}\n# TYPE {name} counter\n{name} {value}\n"));
        }
        out.push_str(&format!(
            "# TYPE telemetry_sink_queue gauge\ntelemetry_sink_queue{{field=\"records\"}} {queued}\ntelemetry_sink_queue{{field=\"bytes\"}} {queued_bytes}\n"
        ));
        if self.last_error_ms > 0 {
            out.push_str(&format!(
                "# TYPE telemetry_sink_last_error_ms gauge\ntelemetry_sink_last_error_ms {}\n",
                self.last_error_ms
            ));
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snapshot_is_zeroed_and_prometheus_names_the_headline() {
        let counters = Counters::new();
        let text = counters.snapshot().prometheus(0, 0);
        assert!(text.contains("telemetry_dropped 0"));
        assert!(text.contains("telemetry_sink_queue{field=\"records\"} 0"));
        assert!(!text.contains("last_error_ms"));
    }

    #[test]
    fn counters_add_up_and_a_failure_is_dated() {
        let counters = Counters::new();
        counters.accepted(3);
        counters.dropped(2);
        counters.otlp_failed(1);
        counters.failed_at(1_700_000_000_000);
        let stats = counters.snapshot();
        assert_eq!(stats.accepted, 3);
        assert_eq!(stats.telemetry_dropped, 2);
        assert_eq!(stats.error_hits, 1);
        let text = stats.prometheus(1, 40);
        assert!(text.contains("telemetry_dropped 2"));
        assert!(text.contains("telemetry_sink_last_error_ms 1700000000000"));
    }
}
