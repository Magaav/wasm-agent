//! "The JSONL is readable" — proven by a real parser, not by a substring.
//!
//! This is the file a human opens the next morning, so the check is: every line is one JSON object,
//! every field has the documented type, a rotated directory stays inside its bound, and the sentence
//! a producer handed in as an attribute is *not* in the file (it is a digest). The same test parses
//! every OTLP body the exporter would post, because a collector's parser is the other reader.
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::Value;
use wa_telemetry_sink::buffer::Bounds;
use wa_telemetry_sink::record::{Attr, Attrs, EventRecord, Id, MetricKind, MetricRecord, Record, Severity, SpanRecord, SpanStatus, TraceId, Unit};
use wa_telemetry_sink::sink::{Config, Sink};
use wa_telemetry_sink::{JsonlConfig, OtlpConfig, Transport};

const SECRET: &str = "sk-abcdefghijklmnop7f2a";
const SENTENCE: &str = "the user asked about their bank statement";

struct Capture {
    bodies: Mutex<Vec<(String, String)>>,
}

impl Transport for Capture {
    fn post(&self, url: &str, _content_type: &str, body: &[u8], _timeout: Duration) -> Result<u16, String> {
        self.bodies.lock().unwrap().push((url.to_string(), String::from_utf8_lossy(body).to_string()));
        Ok(200)
    }
}

fn records() -> Vec<Record> {
    vec![
        Record::Span(SpanRecord {
            component: Id::new("wa-whatsapp"),
            op: Id::new("transcribe"),
            start_ms: 1_700_000_000_123,
            duration_us: 84_000,
            status: SpanStatus::Error,
            trace: Some(TraceId::parse_hex("4bf92f3577b34da6a3ce929d0e0e4736").expect("trace")),
            attrs: Attrs::from(vec![
                Attr::id("status", "error"),
                Attr::count("attempts", 2),
                Attr::from_text("reason", SENTENCE),
                Attr::from_text("credentials", SECRET),
            ]),
        }),
        Record::Metric(MetricRecord {
            component: Id::new("wa-host"),
            name: Id::new("op_duration_micros"),
            kind: MetricKind::Gauge,
            unit: Unit::Micros,
            value: 84_000,
            labels: Attrs::from(vec![Attr::id("op", "run")]),
        }),
        Record::Event(EventRecord {
            topic: Id::new("whatsapp.transcript.ready"),
            source: Id::new("wa-whatsapp"),
            schema: Id::new("wa.whatsapp.transcript"),
            schema_version: 1,
            ts_ms: 1_700_000_001_000,
            count: 3,
            severity: Severity::Warn,
            trace: None,
            attrs: Attrs::from(vec![Attr::count("bytes", 4_096)]),
        }),
    ]
}

fn tempdir(tag: &str) -> std::path::PathBuf {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let dir = std::env::temp_dir().join(format!("wa-sink-jsonl-{tag}-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed)));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

fn files(dir: &std::path::Path) -> Vec<std::path::PathBuf> {
    let mut paths: Vec<_> = std::fs::read_dir(dir)
        .expect("read_dir")
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| path.extension().map(|ext| ext == "jsonl").unwrap_or(false))
        .collect();
    paths.sort();
    paths
}

#[test]
fn every_line_is_one_readable_json_object_and_the_directory_is_bounded() {
    let dir = tempdir("readable");
    let capture = Arc::new(Capture { bodies: Mutex::new(Vec::new()) });
    let mut config = Config { bounds: Bounds::default(), batch_records: 3, jsonl: None, otlp: None };
    config.jsonl = Some(JsonlConfig { dir: dir.clone(), prefix: "telemetry".to_string(), max_bytes: 1 << 20, max_files: 3 });
    config.otlp = Some(OtlpConfig::new("http://127.0.0.1:4318").expect("endpoint"));
    let sink = Sink::with_transport(config, Shared(capture.clone())).expect("open");

    for _ in 0..12 {
        for record in records() {
            assert!(sink.record(record));
        }
    }
    let report = sink.flush();
    assert_eq!(report.drained, 36);
    assert_eq!(report.jsonl_rows, 36);
    assert_eq!(report.jsonl_lost, 0);
    assert_eq!(report.otlp_requests_ok, 36, "one traces/metrics/logs trio per batch of three records");

    let paths = files(&dir);
    assert!(!paths.is_empty());
    assert!(paths.len() <= 3, "the directory stays inside max_files: {paths:?}");
    let mut rows = 0;
    let mut kinds = std::collections::BTreeSet::new();
    for path in &paths {
        let text = std::fs::read_to_string(path).expect("read");
        assert!(!text.contains(SENTENCE), "a digest, not the message: {}", path.display());
        assert!(!text.contains(SECRET), "a secret never reaches the file: {}", path.display());
        for line in text.lines() {
            let value: Value = serde_json::from_str(line).unwrap_or_else(|error| panic!("unreadable line {line}: {error}"));
            let object = value.as_object().expect("an object");
            assert!(object["ts"].as_str().expect("ts").ends_with('Z'));
            let kind = object["kind"].as_str().expect("kind");
            assert!(matches!(kind, "span" | "metric" | "event"), "{kind}");
            kinds.insert(kind.to_string());
            match kind {
                "span" => {
                    assert!(object["component"].is_string());
                    assert!(object["op"].is_string());
                    assert!(object["status"].is_string());
                    assert!(object["duration_us"].is_u64());
                    assert!(object["trace"].is_string());
                    let attrs = object["attrs"].as_object().expect("attrs");
                    assert_eq!(attrs["status"], "error");
                    assert_eq!(attrs["attempts"], 2);
                    assert_eq!(attrs["credentials"], "<redacted>");
                    let digest = attrs["reason"].as_object().expect("a digest");
                    assert!(digest["digest"].is_string());
                    assert!(digest["len"].is_u64());
                }
                "metric" => {
                    assert!(object["name"].is_string());
                    assert!(object["value"].is_u64());
                    assert!(object["metric_kind"].is_string());
                }
                "event" => {
                    assert!(object["topic"].is_string());
                    assert!(object["schema_version"].is_u64());
                    assert!(object["severity"].is_string());
                    assert_eq!(object["attrs"]["bytes"], 4_096);
                }
                _ => unreachable!(),
            }
            rows += 1;
        }
    }
    assert_eq!(rows, 36, "every exported record is one readable row");
    assert_eq!(sink.stats().jsonl_rows, 36, "the counter and the file agree");
    assert_eq!(sink.stats().jsonl_failed, 0);
    assert_eq!(kinds.len(), 3);

    // The remote edge is JSON too, and it is the OTLP shape a collector validates.
    let bodies = capture.bodies.lock().unwrap().clone();
    assert_eq!(bodies.len(), 36);
    for (url, body) in &bodies {
        assert!(!body.contains(SENTENCE), "the digest travels, the text does not");
        let value: Value = serde_json::from_str(body).unwrap_or_else(|error| panic!("unreadable OTLP body for {url}: {error}"));
        let root = value.as_object().expect("an object");
        if url.ends_with("/v1/traces") {
            let spans = &root["resourceSpans"][0]["scopeSpans"][0]["spans"];
            assert_eq!(spans.as_array().expect("spans").len(), 1);
            assert_eq!(spans[0]["status"]["code"], 2);
        } else if url.ends_with("/v1/metrics") {
            let metrics = &root["resourceMetrics"][0]["scopeMetrics"][0]["metrics"];
            assert_eq!(metrics[0]["gauge"]["dataPoints"][0]["asInt"], "84000", "{body}");
        } else {
            let logs = &root["resourceLogs"][0]["scopeLogs"][0]["logRecords"];
            assert_eq!(logs[0]["body"]["stringValue"], "whatsapp.transcript.ready");
            assert_eq!(logs[0]["attributes"][4]["value"]["intValue"], "3");
        }
    }
    let _ = std::fs::remove_dir_all(&dir);
}

/// `Arc<Capture>` is a transport, so the test can read what was posted afterwards.
struct Shared(Arc<Capture>);
impl Transport for Shared {
    fn post(&self, url: &str, content_type: &str, body: &[u8], timeout: Duration) -> Result<u16, String> {
        self.0.post(url, content_type, body, timeout)
    }
}
