//! The local export edge: rotating JSONL, one object per line, written by a human days later.
//!
//! This is where JSON belongs. The bus carries typed records ([`crate::codec`]), the buffer carries
//! structs, and only here and in [`crate::otlp`] does a record become text.
//!
//! Bounds are the same as everywhere else in this crate: [`JsonlConfig::max_bytes`] per file and
//! [`JsonlConfig::max_files`] files, so the directory has a fixed ceiling (`max_bytes * max_files`).
//! Rotation is size-based and synchronous — it happens on the exporter's side of the buffer, never on
//! the producer's — and old files are deleted oldest-first, which is what "rotating" has to mean for
//! a directory that is not allowed to grow without a bound.
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use crate::json::{escape, iso8601};
use crate::record::{Record, Severity};
use crate::stats::Counters;

/// Where and how big. `dir` is the only required choice; the rest has a defensible default.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JsonlConfig {
    pub dir: PathBuf,
    /// File prefix: `<prefix>-000042.jsonl`.
    pub prefix: String,
    pub max_bytes: u64,
    pub max_files: usize,
}

impl JsonlConfig {
    pub fn new(dir: impl Into<PathBuf>) -> JsonlConfig {
        JsonlConfig {
            dir: dir.into(),
            prefix: "telemetry".to_string(),
            max_bytes: 8 << 20,
            max_files: 8,
        }
    }

    /// The ceiling this configuration puts on the directory, in bytes.
    pub fn worst_case_bytes(&self) -> u64 {
        self.max_bytes.saturating_mul(self.max_files.max(1) as u64)
    }

    fn file_name(&self, sequence: u64) -> String {
        format!("{}-{sequence:06}.jsonl", self.prefix)
    }
}

/// A rotating writer. Cheap to hold behind a `Mutex`; no background thread and no internal buffering
/// beyond the row it is writing (a lost row must be a row, not a lost block).
pub struct JsonlWriter {
    cfg: JsonlConfig,
    counters: Arc<Counters>,
    file: File,
    path: PathBuf,
    sequence: u64,
    size: u64,
}

impl std::fmt::Debug for JsonlWriter {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("JsonlWriter")
            .field("path", &self.path)
            .field("sequence", &self.sequence)
            .field("size", &self.size)
            .finish()
    }
}

impl JsonlWriter {
    /// Open (or create) the directory and continue the highest existing sequence, so a restart
    /// appends instead of overwriting the file an operator is reading.
    pub fn open(cfg: JsonlConfig, counters: Arc<Counters>) -> std::io::Result<JsonlWriter> {
        fs::create_dir_all(&cfg.dir)?;
        let sequence = highest_sequence(&cfg).unwrap_or(0);
        let path = cfg.dir.join(cfg.file_name(sequence));
        let file = OpenOptions::new().create(true).append(true).open(&path)?;
        let size = file.metadata().map(|meta| meta.len()).unwrap_or(0);
        let writer = JsonlWriter { cfg, counters, file, path, sequence, size };
        prune(&writer.cfg, 0);
        Ok(writer)
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn size(&self) -> u64 {
        self.size
    }

    pub fn config(&self) -> &JsonlConfig {
        &self.cfg
    }

    /// Write one batch, rotating when the current file would exceed its bound. A row that cannot be
    /// written is counted (`jsonl_failed`), never retried into a growing in-memory queue.
    pub fn write_batch(&mut self, records: &[Record], now_ms: u64) -> usize {
        let mut written = 0;
        for record in records {
            let mut line = line(record, now_ms);
            line.push('\n');
            let bytes = line.as_bytes();
            if self.size > 0 && self.size + bytes.len() as u64 > self.cfg.max_bytes && self.rotate().is_err() {
                self.counters.jsonl_failed(1);
                continue;
            }
            match self.file.write_all(bytes) {
                Ok(()) => {
                    self.size += bytes.len() as u64;
                    written += 1;
                    self.counters.jsonl_rows(1);
                    self.counters.jsonl_bytes(bytes.len() as u64);
                }
                Err(_) => self.counters.jsonl_failed(1),
            }
        }
        if written > 0 {
            let _ = self.file.flush();
        }
        written
    }

    fn rotate(&mut self) -> std::io::Result<()> {
        let _ = self.file.flush();
        self.sequence += 1;
        let path = self.cfg.dir.join(self.cfg.file_name(self.sequence));
        let file = OpenOptions::new().create(true).append(true).open(&path)?;
        self.file = file;
        self.path = path;
        self.size = 0;
        self.counters.jsonl_rotations(1);
        prune(&self.cfg, self.sequence);
        Ok(())
    }
}

/// Sequence numbers present in the directory, newest last. Files this crate did not name are left
/// alone: the sink owns its prefix and nothing else.
fn sequences(cfg: &JsonlConfig) -> Vec<u64> {
    let mut found = Vec::new();
    let Ok(entries) = fs::read_dir(&cfg.dir) else { return found };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        let Some(rest) = name.strip_prefix(&format!("{}-", cfg.prefix)) else { continue };
        let Some(stem) = rest.strip_suffix(".jsonl") else { continue };
        if let Ok(sequence) = stem.parse::<u64>() {
            found.push(sequence);
        }
    }
    found.sort_unstable();
    found
}

fn highest_sequence(cfg: &JsonlConfig) -> Option<u64> {
    sequences(cfg).last().copied()
}

/// Delete the oldest files beyond `max_files`. Errors are ignored on purpose: a file that cannot be
/// removed (open elsewhere) is retried on the next rotation, and reporting it here would need a
/// counter for "housekeeping", which no operator asked for.
fn prune(cfg: &JsonlConfig, current: u64) {
    let all = sequences(cfg);
    let keep = cfg.max_files.max(1);
    if all.len() <= keep {
        return;
    }
    let remove_count = all.len() - keep;
    for sequence in all.into_iter().filter(|sequence| *sequence != current).take(remove_count) {
        let _ = fs::remove_file(cfg.dir.join(cfg.file_name(sequence)));
    }
}

/// One human-readable line. Keys are stable, order is fixed, and every text value went through the
/// id or attribute boundary before it got here, so `escape` is a safety net rather than a policy.
pub fn line(record: &Record, now_ms: u64) -> String {
    let ms = if record.ts_ms() > 0 { record.ts_ms() } else { now_ms };
    let mut out = String::with_capacity(160);
    out.push_str("{\"ts\":\"");
    out.push_str(&iso8601(ms));
    out.push_str("\",\"kind\":\"");
    out.push_str(record.kind_str());
    out.push('"');
    match record {
        Record::Span(span) => {
            out.push_str(&format!(",\"component\":\"{}\"", escape(span.component.as_str())));
            out.push_str(&format!(",\"op\":\"{}\"", escape(span.op.as_str())));
            out.push_str(&format!(",\"status\":\"{}\"", span.status.as_str()));
            out.push_str(&format!(",\"duration_us\":{}", span.duration_us));
            out.push_str(&format!(",\"start_ms\":{}", span.start_ms));
            push_trace(&mut out, record);
            push_attrs(&mut out, "attrs", record);
        }
        Record::Metric(metric) => {
            out.push_str(&format!(",\"component\":\"{}\"", escape(metric.component.as_str())));
            out.push_str(&format!(",\"name\":\"{}\"", escape(metric.name.as_str())));
            out.push_str(&format!(",\"metric_kind\":\"{}\"", metric.kind.as_str()));
            out.push_str(&format!(",\"unit\":\"{}\"", metric.unit.as_str()));
            out.push_str(&format!(",\"value\":{}", metric.value));
            push_attrs(&mut out, "labels", record);
        }
        Record::Event(event) => {
            out.push_str(&format!(",\"topic\":\"{}\"", escape(event.topic.as_str())));
            out.push_str(&format!(",\"source\":\"{}\"", escape(event.source.as_str())));
            out.push_str(&format!(",\"schema\":\"{}\"", escape(event.schema.as_str())));
            out.push_str(&format!(",\"schema_version\":{}", event.schema_version));
            out.push_str(&format!(",\"severity\":\"{}\"", event.severity.as_str()));
            out.push_str(&format!(",\"count\":{}", event.count));
            if event.severity == Severity::Error || event.severity == Severity::Critical {
                out.push_str(",\"alert\":true");
            }
            push_trace(&mut out, record);
            push_attrs(&mut out, "attrs", record);
        }
    }
    out.push('}');
    out
}

fn push_trace(out: &mut String, record: &Record) {
    match record.trace() {
        Some(trace) => out.push_str(&format!(",\"trace\":\"{}\"", trace.to_hex())),
        None => out.push_str(",\"trace\":null"),
    }
}

fn push_attrs(out: &mut String, name: &str, record: &Record) {
    out.push_str(&format!(",\"{name}\":{{"));
    for (index, attr) in record.attrs().iter().enumerate() {
        if index > 0 {
            out.push(',');
        }
        out.push_str(&format!("\"{}\":{}", escape(attr.key.as_str()), attr.value_json()));
    }
    out.push('}');
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::record::{Attr, AttrValue, Attrs, EventRecord, Id, MetricKind, Record, SpanRecord, SpanStatus, TraceId, Unit};
    use crate::stats::Counters;

    fn span() -> Record {
        Record::Span(SpanRecord {
            component: Id::new("wa-whatsapp"),
            op: Id::new("transcribe"),
            start_ms: 1_700_000_000_123,
            duration_us: 84_000,
            status: SpanStatus::Error,
            trace: Some(TraceId::parse_hex("4bf92f3577b34da6a3ce929d0e0e4736").unwrap()),
            attrs: Attrs::from(vec![Attr::id("status", "error"), Attr::from_text("reason", "decode failed early")]),
        })
    }

    #[test]
    fn a_span_line_is_readable_and_exact() {
        let text = line(&span(), 0);
        let reason = "decode failed early";
        let expected = format!(
            "{{\"ts\":\"2023-11-14T22:13:20.123Z\",\"kind\":\"span\",\"component\":\"wa-whatsapp\",\"op\":\"transcribe\",\"status\":\"error\",\"duration_us\":84000,\"start_ms\":1700000000123,\"trace\":\"4bf92f3577b34da6a3ce929d0e0e4736\",\"attrs\":{{\"reason\":{{\"len\":{},\"digest\":\"{:016x}\"}},\"status\":\"error\"}}}}",
            reason.len(),
            crate::hash::fnv1a64(reason.as_bytes())
        );
        assert_eq!(text, expected);
    }

    #[test]
    fn metric_and_event_lines_keep_their_shape() {
        let metric = Record::metric("wa-host", "gpu_queue_depth", MetricKind::Gauge, Unit::Count, 3);
        assert_eq!(
            line(&metric, 1_700_000_000_000),
            "{\"ts\":\"2023-11-14T22:13:20.000Z\",\"kind\":\"metric\",\"component\":\"wa-host\",\"name\":\"gpu_queue_depth\",\"metric_kind\":\"gauge\",\"unit\":\"1\",\"value\":3,\"labels\":{}}"
        );
        let event = Record::Event(EventRecord {
            topic: Id::new("whatsapp.transcript.ready"),
            source: Id::new("wa-whatsapp"),
            schema: Id::new("wa.whatsapp.transcript"),
            schema_version: 2,
            ts_ms: 0,
            count: 5,
            severity: Severity::Error,
            trace: None,
            attrs: Attrs::from(vec![Attr::count("attempts", 3)]),
        });
        assert_eq!(
            line(&event, 1_700_000_000_000),
            "{\"ts\":\"2023-11-14T22:13:20.000Z\",\"kind\":\"event\",\"topic\":\"whatsapp.transcript.ready\",\"source\":\"wa-whatsapp\",\"schema\":\"wa.whatsapp.transcript\",\"schema_version\":2,\"severity\":\"error\",\"count\":5,\"alert\":true,\"trace\":null,\"attrs\":{\"attempts\":3}}"
        );
    }

    #[test]
    fn a_masked_attribute_renders_as_masked() {
        let mut record = span();
        if let Record::Span(span) = &mut record {
            span.attrs.push(Attr::from_text("credentials", "sk-abcdefghijklmn7f2a"));
        }
        let text = line(&record, 0);
        assert!(!text.contains("abcdefghijklmn"), "{text}");
        assert!(text.contains("\"credentials\":\"<redacted>\""), "{text}");
        assert!(matches!(record.attrs().get("credentials"), Some(AttrValue::Redacted)));
    }

    #[test]
    fn lines_are_one_per_record_and_survive_a_tricky_name() {
        let mut record = Record::event("a.b", "c", "d.e", 1);
        if let Record::Event(event) = &mut record {
            event.topic = Id::new("quote\"and\\slash");
        }
        let text = line(&record, 1);
        assert_eq!(text.matches('\n').count(), 0);
        assert!(text.contains("quote_and_slash"), "{text}");
    }

    fn tempdir(tag: &str) -> PathBuf {
        let base = std::env::temp_dir().join(format!("wa-sink-{tag}-{}-{}", std::process::id(), crate::sink::test_clock()));
        let _ = fs::remove_dir_all(&base);
        base
    }

    #[test]
    fn writer_rotates_and_the_directory_stays_bounded() {
        let dir = tempdir("jsonl-rotate");
        let counters = Arc::new(Counters::new());
        let cfg = JsonlConfig { dir: dir.clone(), prefix: "t".to_string(), max_bytes: 400, max_files: 3 };
        let mut writer = JsonlWriter::open(cfg.clone(), counters.clone()).expect("open");
        for _ in 0..40 {
            writer.write_batch(std::slice::from_ref(&span()), 0);
        }
        let files = sequences(&cfg);
        assert!(files.len() <= 3, "{files:?}");
        assert!(dir.exists());
        let total: u64 = files
            .iter()
            .map(|sequence| fs::metadata(dir.join(cfg.file_name(*sequence))).map(|m| m.len()).unwrap_or(0))
            .sum();
        assert!(total <= cfg.worst_case_bytes(), "{total}");
        let stats = counters.snapshot();
        assert_eq!(stats.jsonl_rows, 40);
        assert!(stats.jsonl_rotations >= 1);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn writer_continues_the_highest_sequence_after_a_restart() {
        let dir = tempdir("jsonl-restart");
        let counters = Arc::new(Counters::new());
        let cfg = JsonlConfig { dir: dir.clone(), prefix: "t".to_string(), max_bytes: 100_000, max_files: 4 };
        {
            let mut first = JsonlWriter::open(cfg.clone(), counters.clone()).expect("open");
            for _ in 0..10 {
                first.write_batch(std::slice::from_ref(&span()), 0);
            }
        }
        let highest = highest_sequence(&cfg).expect("a file");
        let mut second = JsonlWriter::open(cfg.clone(), counters.clone()).expect("reopen");
        assert_eq!(second.sequence, highest);
        let before = fs::metadata(second.path()).expect("meta").len();
        second.write_batch(std::slice::from_ref(&span()), 0);
        assert!(fs::metadata(second.path()).expect("meta").len() > before, "append, not overwrite");
        let text = fs::read_to_string(second.path()).expect("read");
        assert!(text.lines().all(|line| line.starts_with('{') && line.ends_with('}')));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn writer_keeps_rows_when_a_rotation_leaves_only_one_file() {
        let dir = tempdir("jsonl-single");
        let counters = Arc::new(Counters::new());
        let cfg = JsonlConfig { dir: dir.clone(), prefix: "t".to_string(), max_bytes: 10, max_files: 1 };
        let mut writer = JsonlWriter::open(cfg, counters.clone()).expect("open");
        let rows = writer.write_batch(std::slice::from_ref(&span()), 0);
        assert_eq!(rows, 1, "with one file there is nothing to rotate into; the row is still written");
        let _ = fs::remove_dir_all(&dir);
    }
}
