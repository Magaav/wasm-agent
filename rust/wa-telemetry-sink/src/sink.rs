//! The sink: one buffer, one (optional) local file edge, one (optional) OTLP edge, and the numbers
//! that say what happened. Nothing here has a thread or a timer of its own.
//!
//! That is deliberate and is the same rule `wa-telemetry` follows: the node already ticks once a
//! second, so the sink's `pump` is called from that tick (or from a dedicated exporter task the host
//! owns). The producer side — [`Sink::record`] — takes the buffer's mutex, evicts if needed, and
//! returns. It never writes, never dials, and cannot be blocked by a dead collector.
//!
//! Two edges, two guarantees:
//!
//! * **JSONL is the record.** It is on by default, bounded (`max_bytes × max_files`), and a write
//!   failure is counted (`jsonl_failed`) rather than retried into a growing queue.
//! * **OTLP is best effort.** A collector that is down costs one counted request per flush and the
//!   batch is dropped with `otlp_dropped`; when it comes back, `otlp_recovered` says so. A retry ring
//!   would make the sink's memory a function of the collector's health, which is exactly the coupling
//!   this component exists to remove.
use std::io;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::buffer::{Bounds, Ring};
use crate::codec::{self, CodecError};
use crate::jsonl::{JsonlConfig, JsonlWriter};
use crate::otlp::{ConfigError, OtlpConfig, OtlpExporter, TcpTransport, Transport};
use crate::record::Record;
use crate::stats::{Counters, SinkStats};

/// Everything the sink's owner decides up front. A `Config` with no `jsonl` and no `otlp` is legal
/// and is what a "measure the buffer only" check uses.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Config {
    pub bounds: Bounds,
    /// Records per flush. The buffer is the backpressure; this is the batch shape.
    pub batch_records: usize,
    pub jsonl: Option<JsonlConfig>,
    pub otlp: Option<OtlpConfig>,
}

impl Default for Config {
    fn default() -> Config {
        Config { bounds: Bounds::default(), batch_records: 256, jsonl: None, otlp: None }
    }
}

impl Config {
    pub fn with_jsonl(mut self, dir: impl Into<std::path::PathBuf>) -> Config {
        self.jsonl = Some(JsonlConfig::new(dir));
        self
    }

    pub fn with_otlp(mut self, endpoint: &str) -> Result<Config, ConfigError> {
        self.otlp = Some(OtlpConfig::new(endpoint)?);
        Ok(self)
    }

    /// The small, directory-scoped configuration the tests use.
    pub fn for_tests(dir: impl Into<std::path::PathBuf>) -> Config {
        Config {
            bounds: Bounds::for_tests(),
            batch_records: 64,
            jsonl: Some(JsonlConfig::new(dir)),
            otlp: None,
        }
    }
}

/// What one flush did, so a caller can log a line without reading counters.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct FlushReport {
    pub drained: usize,
    pub jsonl_rows: usize,
    pub jsonl_lost: u64,
    pub otlp_requests_ok: u32,
    pub otlp_requests_failed: u32,
    pub otlp_error: Option<String>,
}

/// The sink. Generic over the HTTP transport so a test (and the host, for TLS) can supply one.
pub struct Sink<T: Transport = TcpTransport> {
    cfg: Config,
    counters: Arc<Counters>,
    ring: Ring,
    jsonl: Mutex<Option<JsonlWriter>>,
    otlp: Option<OtlpExporter<T>>,
    /// Was the last OTLP flush a failure? Only used to count the *transition* to healthy.
    failing: AtomicBool,
    batches: AtomicU64,
}

impl Sink<TcpTransport> {
    /// Open with the real (plaintext HTTP) transport. Fails only when the JSONL directory cannot be
    /// created; an unwritable directory is a configuration error a node should hear about at start.
    pub fn open(cfg: Config) -> io::Result<Sink<TcpTransport>> {
        Sink::with_transport(cfg, TcpTransport)
    }
}

impl<T: Transport> Sink<T> {
    pub fn with_transport(cfg: Config, transport: T) -> io::Result<Sink<T>> {
        let counters = Arc::new(Counters::new());
        let ring = Ring::new(cfg.bounds, counters.clone());
        let jsonl = match &cfg.jsonl {
            Some(config) => Some(JsonlWriter::open(config.clone(), counters.clone())?),
            None => None,
        };
        let otlp = cfg.otlp.clone().map(|config| OtlpExporter::new(config, transport));
        Ok(Sink {
            cfg,
            counters,
            ring,
            jsonl: Mutex::new(jsonl),
            otlp,
            failing: AtomicBool::new(false),
            batches: AtomicU64::new(0),
        })
    }

    pub fn config(&self) -> &Config {
        &self.cfg
    }

    pub fn counters(&self) -> &Arc<Counters> {
        &self.counters
    }

    /// The producer's entry point. Bounded work, no I/O, no waiting: it takes the buffer's mutex,
    /// evicts the oldest records if the budget is full (counting them in `telemetry_dropped`), and
    /// returns whether the record was kept.
    pub fn record(&self, record: Record) -> bool {
        self.ring.push(record)
    }

    /// Decode a `wa:telemetry` frame (what the sink component sends over the bus or the host
    /// provider) and record every item. Returns the number kept.
    pub fn submit_frame(&self, frame: &[u8]) -> Result<usize, CodecError> {
        let records = codec::decode(frame)?;
        Ok(records.into_iter().filter(|record| self.ring.push(record.clone())).count())
    }

    /// Flush at most `batch_records` records. Cheap when there is nothing to do: one mutex and an
    /// empty `Vec`.
    pub fn pump(&self) -> FlushReport {
        self.pump_at(now_ms())
    }

    pub fn pump_at(&self, now_ms: u64) -> FlushReport {
        let before = self.counters.snapshot();
        let batch = self.ring.drain(self.cfg.batch_records.max(1));
        let mut report = FlushReport { drained: batch.len(), ..FlushReport::default() };
        if batch.is_empty() {
            return report;
        }
        self.batches.fetch_add(1, Ordering::Relaxed);
        self.counters.exported(batch.len() as u64);
        self.counters.exported_batches(1);

        if let Some(writer) = self.jsonl.lock().unwrap_or_else(|poison| poison.into_inner()).as_mut() {
            report.jsonl_rows = writer.write_batch(&batch, now_ms);
        }

        if let Some(exporter) = &self.otlp {
            let outcome = exporter.export(&batch, now_ms);
            report.otlp_requests_ok = outcome.requests_ok;
            report.otlp_requests_failed = outcome.requests_failed;
            if outcome.requests > 0 {
                if outcome.is_ok() {
                    self.counters.otlp_sent(outcome.requests_ok as u64);
                    if self.failing.swap(false, Ordering::SeqCst) {
                        self.counters.otlp_recovered(1);
                    }
                } else {
                    report.otlp_error = outcome.first_error.clone();
                    self.counters.otlp_failed(1);
                    self.counters.otlp_dropped(batch.len() as u64);
                    self.counters.failed_at(now_ms);
                    self.failing.store(true, Ordering::SeqCst);
                }
            }
        }

        let after = self.counters.snapshot();
        report.jsonl_lost = after.jsonl_failed.saturating_sub(before.jsonl_failed);
        report
    }

    /// Flush until the buffer is empty, or until `max_batches` flushes have run (a producer that
    /// outruns the flusher should not make shutdown unbounded — the count says how much was left).
    pub fn flush(&self) -> FlushReport {
        self.flush_max(1_024)
    }

    pub fn flush_max(&self, max_batches: usize) -> FlushReport {
        let mut total = FlushReport::default();
        for _ in 0..max_batches.max(1) {
            let report = self.pump();
            if report.drained == 0 {
                break;
            }
            total.drained += report.drained;
            total.jsonl_rows += report.jsonl_rows;
            total.jsonl_lost += report.jsonl_lost;
            total.otlp_requests_ok += report.otlp_requests_ok;
            total.otlp_requests_failed += report.otlp_requests_failed;
            if total.otlp_error.is_none() {
                total.otlp_error = report.otlp_error;
            }
        }
        total
    }

    pub fn stats(&self) -> SinkStats {
        self.counters.snapshot()
    }

    /// `(records, bytes)` currently queued.
    pub fn queued(&self) -> (usize, usize) {
        (self.ring.len(), self.ring.bytes())
    }

    pub fn batches(&self) -> u64 {
        self.batches.load(Ordering::Relaxed)
    }

    pub fn prometheus(&self) -> String {
        let (records, bytes) = self.queued();
        self.counters.snapshot().prometheus(records, bytes)
    }

    /// The JSONL file being written right now, if the local edge is on (for a log line, not a read).
    pub fn jsonl_path(&self) -> Option<std::path::PathBuf> {
        self.jsonl
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .as_ref()
            .map(|writer| writer.path().to_path_buf())
    }

}

pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as u64)
        .unwrap_or(0)
}

/// A monotonic counter the tests use to name a directory; not part of the sink's contract.
#[cfg(test)]
pub(crate) fn test_clock() -> u64 {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    NEXT.fetch_add(1, Ordering::Relaxed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::record::{Attr, EventRecord, Id, MetricKind, Record, Severity, SpanStatus, Unit};
    use std::sync::Mutex;
    use std::time::Duration;

    struct Server {
        posts: Mutex<Vec<String>>,
        answer: Mutex<Result<u16, String>>,
    }

    impl Transport for Server {
        fn post(&self, _url: &str, _ct: &str, body: &[u8], _t: Duration) -> Result<u16, String> {
            self.posts.lock().unwrap().push(String::from_utf8_lossy(body).to_string());
            self.answer.lock().unwrap().clone()
        }
    }

    impl Server {
        fn new(answer: Result<u16, String>) -> Server {
            Server { posts: Mutex::new(Vec::new()), answer: Mutex::new(answer) }
        }
        fn set(&self, answer: Result<u16, String>) {
            *self.answer.lock().unwrap() = answer;
        }
    }

    fn tempdir(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("wa-sink-{tag}-{}-{}", std::process::id(), test_clock()));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    fn event(index: u64) -> Record {
        Record::Event(EventRecord {
            topic: Id::new("test.topic"),
            source: Id::new("test"),
            schema: Id::new("test.event"),
            schema_version: 1,
            ts_ms: index,
            count: 1,
            severity: Severity::Info,
            trace: None,
            attrs: Default::default(),
        })
    }

    #[test]
    fn a_sink_without_edges_only_buffers() {
        let dir = tempdir("no-edges");
        let cfg = Config { bounds: Bounds { max_records: 2, ..Bounds::for_tests() }, batch_records: 8, jsonl: None, otlp: None };
        let sink: Sink<TcpTransport> = Sink::open(cfg).expect("open");
        for index in 0..5 {
            assert!(sink.record(event(index)));
        }
        assert_eq!(sink.queued().0, 2);
        let stats = sink.stats();
        assert_eq!(stats.telemetry_dropped, 3);
        let report = sink.flush();
        assert_eq!(report.drained, 2);
        assert_eq!(sink.queued().0, 0);
        assert_eq!(sink.stats().exported, 2);
        assert_eq!(sink.jsonl_path(), None);
        assert!(dir.as_os_str().is_empty() || !dir.exists());
    }

    #[test]
    fn jsonl_is_the_record_and_pump_writes_it() {
        let dir = tempdir("jsonl");
        let sink: Sink<TcpTransport> = Sink::open(Config::for_tests(&dir)).expect("open");
        for index in 0..3 {
            sink.record(event(index));
        }
        let report = sink.pump_at(1_700_000_000_000);
        assert_eq!(report.drained, 3);
        assert_eq!(report.jsonl_rows, 3);
        assert_eq!(report.jsonl_lost, 0);
        let path = sink.jsonl_path().expect("a file");
        let text = std::fs::read_to_string(path).expect("read");
        assert_eq!(text.lines().count(), 3);
        assert!(text.contains("\"topic\":\"test.topic\""), "{text}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn otlp_outage_drops_with_a_count_and_recovers() {
        let dir = tempdir("otlp");
        let server = std::sync::Arc::new(Server::new(Err("connect_failed:ConnectionRefused".to_string())));
        let mut cfg = Config::for_tests(&dir);
        cfg.otlp = Some(OtlpConfig::new("http://127.0.0.1:4318").expect("cfg"));
        let sink = Sink::with_transport(cfg, Shared(server.clone())).expect("open");
        sink.record(event(1));
        let report = sink.pump_at(5);
        assert_eq!(report.otlp_requests_failed, 1);
        assert!(report.otlp_error.is_some());
        assert_eq!(sink.stats().telemetry_dropped, 0, "an OTLP loss is counted, but the buffer kept nothing");
        assert_eq!(sink.stats().otlp_dropped, 1);
        assert_eq!(sink.stats().otlp_failed, 1);

        server.set(Ok(200));
        sink.record(event(2));
        let report = sink.pump_at(6);
        assert_eq!(report.otlp_requests_ok, 1);
        assert_eq!(sink.stats().otlp_recovered, 1);
        assert_eq!(sink.stats().otlp_sent, 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_frame_from_the_component_is_recorded() {
        let dir = tempdir("frame");
        let sink: Sink<TcpTransport> = Sink::open(Config::for_tests(&dir)).expect("open");
        let frame = codec::encode(&[
            Record::span("wa-host", "run", 1, 2, SpanStatus::Ok),
            Record::metric("wa-host", "op_total", MetricKind::Counter, Unit::Count, 4),
        ])
        .expect("encode");
        assert_eq!(sink.submit_frame(&frame).expect("decode"), 2);
        assert_err(sink.submit_frame(b"nope"));
        let report = sink.pump_at(1);
        assert_eq!(report.drained, 2);
        assert_eq!(report.jsonl_rows, 2);
        let _ = std::fs::remove_dir_all(&dir);
    }

    fn assert_err(result: Result<usize, CodecError>) {
        assert!(result.is_err());
    }

    #[test]
    fn record_with_redacted_attrs_is_counted() {
        let dir = tempdir("redact");
        let sink: Sink<TcpTransport> = Sink::open(Config::for_tests(&dir)).expect("open");
        let mut record = match event(1) {
            Record::Event(event) => event,
            _ => unreachable!(),
        };
        record.attrs.push(Attr::from_text("auth", "sk-abcdefghijklmn7f2a"));
        record.attrs.push(Attr::from_text("note", "some words here"));
        sink.record(Record::Event(record));
        let stats = sink.stats();
        assert_eq!(stats.attrs_redacted, 1);
        assert_eq!(stats.attrs_digested, 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    struct Shared(std::sync::Arc<Server>);
    impl Transport for Shared {
        fn post(&self, url: &str, ct: &str, body: &[u8], timeout: Duration) -> Result<u16, String> {
            self.0.post(url, ct, body, timeout)
        }
    }
}
