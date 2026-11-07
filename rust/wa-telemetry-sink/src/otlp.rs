//! The optional remote edge: OTLP/HTTP JSON to the one collector the sink was configured with.
//!
//! Three rules make this edge safe enough to switch on:
//!
//! 1. **One destination.** [`OtlpConfig`] parses the endpoint once; every request URL is built by the
//!    exporter from that parsed host, port and base path, and [`OtlpExporter::check_url`] refuses
//!    anything else before a byte is sent. That is the manifest grant (`http` to that host only) made
//!    mechanical instead of remembered.
//! 2. **No redirects, no credentials in the URL.** The transport sends one request and reads one
//!    response. A `3xx` is a failure, not a new destination; userinfo in the endpoint is refused at
//!    configuration time (a token in a URL ends up in an error string).
//! 3. **Failure is counted, not retried into memory.** The local JSONL file is the complete record;
//!    a batch the collector refuses is dropped with `otlp_failed`/`otlp_dropped` and the *next*
//!    success increments `otlp_recovered`. Nothing queues behind a dead collector.
//!
//! TLS is deliberately not here: `TcpTransport` speaks `http://` only, and an operator who needs
//! `https://` injects a `Transport` from the host (which already owns rustls and its grants).
use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::time::Duration;

use crate::json::{escape, iso8601};
use crate::record::{Id, MetricKind, Record, Severity};
use crate::redact;

/// The three OTLP/HTTP signal paths, in the order the exporter posts them.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Signal {
    Traces,
    Metrics,
    Logs,
}

impl Signal {
    pub fn path(self) -> &'static str {
        match self {
            Signal::Traces => "/v1/traces",
            Signal::Metrics => "/v1/metrics",
            Signal::Logs => "/v1/logs",
        }
    }

    pub fn of(record: &Record) -> Signal {
        match record {
            Record::Span(_) => Signal::Traces,
            Record::Metric(_) => Signal::Metrics,
            Record::Event(_) => Signal::Logs,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ConfigError {
    /// Only `http://` endpoints are accepted by this crate.
    UnsupportedScheme,
    MissingHost,
    /// `user:password@host` or a query/fragment: a place a credential can hide.
    NotAnEndpoint,
    BadPort,
}

impl std::fmt::Display for ConfigError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            ConfigError::UnsupportedScheme => "unsupported_scheme",
            ConfigError::MissingHost => "missing_host",
            ConfigError::NotAnEndpoint => "not_an_endpoint",
            ConfigError::BadPort => "bad_port",
        })
    }
}

impl std::error::Error for ConfigError {}

/// A parsed `http://host[:port][/base]`. Nothing else is accepted, on purpose.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Endpoint {
    host: String,
    port: u16,
    base_path: String,
}

impl Endpoint {
    pub fn parse(raw: &str) -> Result<Endpoint, ConfigError> {
        let Some(rest) = raw.strip_prefix("http://") else {
            return Err(if raw.starts_with("https://") { ConfigError::UnsupportedScheme } else { ConfigError::NotAnEndpoint });
        };
        if rest.contains('@') || rest.contains('?') || rest.contains('#') || rest.chars().any(|ch| ch.is_whitespace()) {
            return Err(ConfigError::NotAnEndpoint);
        }
        let (authority, base_path) = match rest.find('/') {
            Some(index) => (&rest[..index], rest[index..].trim_end_matches('/').to_string()),
            None => (rest, String::new()),
        };
        let (host, port) = match authority.rsplit_once(':') {
            Some((host, port)) if !host.is_empty() => {
                let port = port.parse::<u16>().map_err(|_| ConfigError::BadPort)?;
                (host, port)
            }
            Some(_) => return Err(ConfigError::MissingHost),
            None => (authority, 4318),
        };
        if host.is_empty() {
            return Err(ConfigError::MissingHost);
        }
        Ok(Endpoint { host: host.to_string(), port, base_path })
    }

    pub fn host(&self) -> &str {
        &self.host
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    pub fn base_path(&self) -> &str {
        &self.base_path
    }

    /// The only way a URL is produced. A signal path is a constant from [`Signal`], never a string a
    /// record could influence.
    pub fn url(&self, signal: Signal) -> String {
        format!("http://{}:{}{}{}", self.host, self.port, self.base_path, signal.path())
    }

    pub fn authority(&self) -> String {
        format!("{}:{}", self.host, self.port)
    }
}

/// The collector, its identity and its bounds.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OtlpConfig {
    pub endpoint: Endpoint,
    /// `service.name` as the collector sees it; a name, so it is safe to export.
    pub service_name: Id,
    pub timeout_ms: u64,
    /// Records per request. A batch is already bounded by the buffer; this splits it further so one
    /// huge push is not one huge POST.
    pub max_batch: usize,
}

impl OtlpConfig {
    pub fn new(endpoint: &str) -> Result<OtlpConfig, ConfigError> {
        Ok(OtlpConfig {
            endpoint: Endpoint::parse(endpoint)?,
            service_name: Id::new("wa-node"),
            timeout_ms: 2_000,
            max_batch: 512,
        })
    }

    pub fn with_service(mut self, name: &str) -> OtlpConfig {
        self.service_name = Id::new(name);
        self
    }
}

/// One HTTP POST. Injected so a test can answer without a socket, and so the host can supply TLS.
pub trait Transport: Send + Sync {
    fn post(&self, url: &str, content_type: &str, body: &[u8], timeout: Duration) -> Result<u16, String>;
}

/// Plaintext HTTP/1.1, one request, `Connection: close`. No redirect, no retry, no TLS.
#[derive(Clone, Copy, Debug, Default)]
pub struct TcpTransport;

impl Transport for TcpTransport {
    fn post(&self, url: &str, content_type: &str, body: &[u8], timeout: Duration) -> Result<u16, String> {
        let Some(rest) = url.strip_prefix("http://") else { return Err("scheme_not_http".to_string()) };
        let (authority, path) = match rest.find('/') {
            Some(index) => (&rest[..index], &rest[index..]),
            None => (rest, "/"),
        };
        if authority.contains('@') || path.contains(' ') || path.contains('\r') || path.contains('\n') {
            return Err("bad_url".to_string());
        }
        let (host, port) = match authority.rsplit_once(':') {
            Some((host, port)) => (host, port.parse::<u16>().map_err(|_| "bad_port".to_string())?),
            None => (authority, 4318),
        };
        let addresses: Vec<_> = (host, port).to_socket_addrs().map_err(|_| "resolve_failed".to_string())?.collect();
        let mut last = "connect_failed".to_string();
        for address in addresses {
            match TcpStream::connect_timeout(&address, timeout) {
                Ok(mut stream) => {
                    let _ = stream.set_read_timeout(Some(timeout));
                    let _ = stream.set_write_timeout(Some(timeout));
                    let head = format!(
                        "POST {path} HTTP/1.1\r\nHost: {authority}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        body.len()
                    );
                    if stream.write_all(head.as_bytes()).and_then(|()| stream.write_all(body)).is_err() {
                        last = "write_failed".to_string();
                        continue;
                    }
                    let mut response = Vec::with_capacity(512);
                    let mut buffer = [0u8; 512];
                    loop {
                        match stream.read(&mut buffer) {
                            Ok(0) => break,
                            Ok(read) => {
                                response.extend_from_slice(&buffer[..read]);
                                if response.len() > 8 << 10 || response.windows(4).any(|window| window == b"\r\n\r\n") {
                                    break;
                                }
                            }
                            Err(_) => break,
                        }
                    }
                    return parse_status(&response).ok_or_else(|| "no_status".to_string());
                }
                Err(error) => last = format!("connect_failed:{}", error.kind()),
            }
        }
        Err(last)
    }
}

fn parse_status(response: &[u8]) -> Option<u16> {
    let text = std::str::from_utf8(&response[..response.iter().position(|byte| *byte == b'\r' || *byte == b'\n').unwrap_or(response.len())]).ok()?;
    let mut parts = text.split_whitespace();
    let _version = parts.next()?;
    parts.next()?.parse::<u16>().ok()
}

/// What one `export` did. Grouped by signal: a collector can accept traces and refuse logs.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ExportOutcome {
    pub requests: u32,
    pub requests_ok: u32,
    pub requests_failed: u32,
    pub first_error: Option<String>,
}

impl ExportOutcome {
    pub fn is_ok(&self) -> bool {
        self.requests_failed == 0
    }
}

/// The exporter: configuration plus a transport. Stateless between batches (no retry ring), so a
/// dead collector costs one counted request per flush and no memory.
pub struct OtlpExporter<T: Transport> {
    cfg: OtlpConfig,
    transport: T,
}

impl<T: Transport> std::fmt::Debug for OtlpExporter<T> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("OtlpExporter").field("endpoint", &self.cfg.endpoint).finish()
    }
}

impl<T: Transport> OtlpExporter<T> {
    pub fn new(cfg: OtlpConfig, transport: T) -> OtlpExporter<T> {
        OtlpExporter { cfg, transport }
    }

    pub fn config(&self) -> &OtlpConfig {
        &self.cfg
    }

    /// The grant, checked per request: the URL must belong to the configured endpoint.
    pub fn check_url(&self, url: &str) -> Result<(), String> {
        let expected = self.cfg.endpoint.authority();
        let Some(rest) = url.strip_prefix("http://") else { return Err("scheme_not_http".to_string()) };
        let authority = rest.split('/').next().unwrap_or("");
        if authority != expected {
            return Err("destination_not_granted".to_string());
        }
        Ok(())
    }

    /// Post every record, grouped by signal and split at `max_batch`. `now_ms` stamps records that
    /// carry no time of their own (metrics are values, not events).
    pub fn export(&self, records: &[Record], now_ms: u64) -> ExportOutcome {
        let mut outcome = ExportOutcome::default();
        for signal in [Signal::Traces, Signal::Metrics, Signal::Logs] {
            let selected: Vec<&Record> = records.iter().filter(|record| Signal::of(record) == signal).collect();
            for chunk in selected.chunks(self.cfg.max_batch.max(1)) {
                let bodies = payload(signal, chunk, &self.cfg, now_ms);
                let url = self.cfg.endpoint.url(signal);
                outcome.requests += 1;
                if let Err(error) = self.check_url(&url) {
                    outcome.requests_failed += 1;
                    outcome.first_error.get_or_insert(error);
                    continue;
                }
                match self.transport.post(&url, "application/json", bodies.as_bytes(), Duration::from_millis(self.cfg.timeout_ms)) {
                    Ok(code) if (200..300).contains(&code) => outcome.requests_ok += 1,
                    Ok(code) => {
                        outcome.requests_failed += 1;
                        outcome.first_error.get_or_insert(format!("http_{code}"));
                    }
                    Err(error) => {
                        outcome.requests_failed += 1;
                        outcome.first_error.get_or_insert(redact::reason(&error, 96));
                    }
                }
            }
        }
        outcome
    }
}

/// OTLP/HTTP JSON for one signal. `now_ms` is used only for records that have no timestamp.
pub fn payload(signal: Signal, records: &[&Record], cfg: &OtlpConfig, now_ms: u64) -> String {
    let resource = resource_json(&cfg.service_name);
    let scope = format!("{{\"name\":\"wa-telemetry-sink\",\"version\":\"{}\"}}", env!("CARGO_PKG_VERSION"));
    match signal {
        Signal::Traces => {
            let spans: Vec<String> = records
                .iter()
                .filter_map(|record| match record {
                    Record::Span(span) => Some(span_json(span, now_ms)),
                    _ => None,
                })
                .collect();
            format!(
                "{{\"resourceSpans\":[{{\"resource\":{resource},\"scopeSpans\":[{{\"scope\":{scope},\"spans\":[{}]}}]}}]}}",
                spans.join(",")
            )
        }
        Signal::Metrics => {
            let metrics: Vec<String> = records
                .iter()
                .filter_map(|record| match record {
                    Record::Metric(metric) => Some(metric_json(metric, now_ms)),
                    _ => None,
                })
                .collect();
            format!(
                "{{\"resourceMetrics\":[{{\"resource\":{resource},\"scopeMetrics\":[{{\"scope\":{scope},\"metrics\":[{}]}}]}}]}}",
                metrics.join(",")
            )
        }
        Signal::Logs => {
            let logs: Vec<String> = records
                .iter()
                .filter_map(|record| match record {
                    Record::Event(event) => Some(log_json(event, now_ms)),
                    _ => None,
                })
                .collect();
            format!(
                "{{\"resourceLogs\":[{{\"resource\":{resource},\"scopeLogs\":[{{\"scope\":{scope},\"logRecords\":[{}]}}]}}]}}",
                logs.join(",")
            )
        }
    }
}

fn resource_json(service_name: &Id) -> String {
    format!(
        "{{\"attributes\":[{{\"key\":\"service.name\",\"value\":{{\"stringValue\":\"{}\"}}}}]}}",
        escape(service_name.as_str())
    )
}

fn attrs_json(attrs: &crate::record::Attrs) -> String {
    attrs.iter().map(|attr| attr.otlp_json()).collect::<Vec<_>>().join(",")
}

fn span_json(span: &crate::record::SpanRecord, now_ms: u64) -> String {
    let start_ms = if span.start_ms > 0 { span.start_ms } else { now_ms };
    let start_ns = start_ms.saturating_mul(1_000_000);
    let end_ns = start_ns.saturating_add(span.duration_us.saturating_mul(1_000));
    // A span id is not carried on the wire (the record has no id field); it is derived so two
    // identical spans in one batch are still distinguishable by OTLP's required field.
    let span_id = format!(
        "{:016x}",
        crate::hash::fnv1a64(
            format!("{}:{}:{}:{}", span.component.as_str(), span.op.as_str(), start_ms, span.duration_us).as_bytes()
        )
    );
    let trace = span.trace.unwrap_or_else(|| crate::record::TraceId::from_label(span.op.as_str()));
    let status = match span.status {
        crate::record::SpanStatus::Ok => 1,
        crate::record::SpanStatus::Error | crate::record::SpanStatus::Expired => 2,
        crate::record::SpanStatus::Cancelled => 0,
    };
    let mut attrs = vec![format!(
        "{{\"key\":\"wa.component\",\"value\":{{\"stringValue\":\"{}\"}}}}",
        escape(span.component.as_str())
    )];
    let extra = attrs_json(&span.attrs);
    if !extra.is_empty() {
        attrs.push(extra);
    }
    format!(
        "{{\"traceId\":\"{}\",\"spanId\":\"{span_id}\",\"name\":\"{}\",\"kind\":1,\"startTimeUnixNano\":\"{start_ns}\",\"endTimeUnixNano\":\"{end_ns}\",\"attributes\":[{}],\"status\":{{\"code\":{status}}}}}",
        trace.to_hex(),
        escape(span.op.as_str()),
        attrs.join(",")
    )
}

fn metric_json(metric: &crate::record::MetricRecord, now_ms: u64) -> String {
    let name: String = metric
        .name
        .as_str()
        .chars()
        .map(|ch| if ch.is_ascii_alphanumeric() || matches!(ch, '_' | '.' | '-') { ch } else { '_' })
        .collect();
    let time = now_ms.saturating_mul(1_000_000);
    let points = format!(
        "\"dataPoints\":[{{\"asInt\":\"{}\",\"timeUnixNano\":\"{time}\",\"attributes\":[{}]}}]",
        metric.value,
        attrs_json(&metric.labels)
    );
    // A counter is a monotonic cumulative sum; a gauge is a gauge. Nothing else is claimed: this edge
    // transports values, it does not decide that a histogram is one.
    let (kind, body) = match metric.kind {
        MetricKind::Counter => ("sum", format!("\"aggregationTemporality\":2,\"isMonotonic\":true,{points}")),
        MetricKind::Gauge => ("gauge", points),
    };
    format!("{{\"name\":\"{name}\",\"unit\":\"{}\",\"{kind}\":{{{body}}}}}", metric.unit.otlp_name())
}

fn log_json(event: &crate::record::EventRecord, now_ms: u64) -> String {
    let ms = if event.ts_ms > 0 { event.ts_ms } else { now_ms };
    let time = ms.saturating_mul(1_000_000);
    let mut attrs = vec![
        format!("{{\"key\":\"topic\",\"value\":{{\"stringValue\":\"{}\"}}}}", escape(event.topic.as_str())),
        format!("{{\"key\":\"source\",\"value\":{{\"stringValue\":\"{}\"}}}}", escape(event.source.as_str())),
        format!("{{\"key\":\"schema\",\"value\":{{\"stringValue\":\"{}\"}}}}", escape(event.schema.as_str())),
        format!("{{\"key\":\"schema_version\",\"value\":{{\"intValue\":\"{}\"}}}}", event.schema_version),
        format!("{{\"key\":\"count\",\"value\":{{\"intValue\":\"{}\"}}}}", event.count),
    ];
    let extra = attrs_json(&event.attrs);
    if !extra.is_empty() {
        attrs.push(extra);
    }
    let severity = event.severity;
    format!(
        "{{\"timeUnixNano\":\"{time}\",\"severityNumber\":{},\"severityText\":\"{}\",\"body\":{{\"stringValue\":\"{}\"}},\"attributes\":[{}]}}",
        severity.otlp_number(),
        severity.as_str(),
        escape(event.topic.as_str()),
        attrs.join(",")
    )
}

/// A stamp for humans reading a failure: the same ISO form the JSONL uses.
pub fn stamp(ms: u64) -> String {
    iso8601(ms)
}

/// Kept so `Severity`'s OTLP mapping is exercised from here as well as from `record`.
#[allow(dead_code)]
fn severity_is_closed(severity: Severity) -> u8 {
    severity.otlp_number()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::record::{Attr, Attrs, EventRecord, MetricRecord, SpanRecord, SpanStatus, TraceId, Unit};
    use std::sync::Mutex;

    struct Recorder {
        posts: Mutex<Vec<(String, String)>>,
        code: u16,
    }

    impl Recorder {
        fn new(code: u16) -> Recorder {
            Recorder { posts: Mutex::new(Vec::new()), code }
        }
        fn bodies(&self) -> Vec<(String, String)> {
            self.posts.lock().unwrap().clone()
        }
    }

    impl Transport for Recorder {
        fn post(&self, url: &str, _content_type: &str, body: &[u8], _timeout: Duration) -> Result<u16, String> {
            self.posts.lock().unwrap().push((url.to_string(), String::from_utf8_lossy(body).to_string()));
            Ok(self.code)
        }
    }

    fn records() -> Vec<Record> {
        vec![
            Record::Span(SpanRecord {
                component: Id::new("wa-whatsapp"),
                op: Id::new("transcribe"),
                start_ms: 1_700_000_000_000,
                duration_us: 84_000,
                status: SpanStatus::Error,
                trace: Some(TraceId::parse_hex("4bf92f3577b34da6a3ce929d0e0e4736").unwrap()),
                attrs: Attrs::from(vec![Attr::id("status", "error")]),
            }),
            Record::Metric(MetricRecord {
                component: Id::new("wa-host"),
                name: Id::new("op_total"),
                kind: MetricKind::Counter,
                unit: Unit::Count,
                value: 7,
                labels: Attrs::from(vec![Attr::id("op", "run")]),
            }),
            Record::Event(EventRecord {
                topic: Id::new("whatsapp.transcript.ready"),
                source: Id::new("wa-whatsapp"),
                schema: Id::new("wa.whatsapp.transcript"),
                schema_version: 1,
                ts_ms: 1_700_000_000_500,
                count: 2,
                severity: Severity::Warn,
                trace: None,
                attrs: Attrs::from(vec![Attr::from_text("note", "a long human sentence")]),
            }),
        ]
    }

    #[test]
    fn endpoint_parsing_is_strict() {
        let endpoint = Endpoint::parse("http://127.0.0.1:4318").expect("parse");
        assert_eq!(endpoint.authority(), "127.0.0.1:4318");
        assert_eq!(endpoint.url(Signal::Traces), "http://127.0.0.1:4318/v1/traces");
        assert_eq!(Endpoint::parse("http://collector:4318/otlp").unwrap().url(Signal::Logs), "http://collector:4318/otlp/v1/logs");
        assert_eq!(Endpoint::parse("https://collector").unwrap_err(), ConfigError::UnsupportedScheme);
        assert_eq!(Endpoint::parse("http://user:pw@collector").unwrap_err(), ConfigError::NotAnEndpoint);
        assert_eq!(Endpoint::parse("http://collector/?x=1").unwrap_err(), ConfigError::NotAnEndpoint);
        assert_eq!(Endpoint::parse("http://:4318").unwrap_err(), ConfigError::MissingHost);
        assert_eq!(Endpoint::parse("http://collector:notaport").unwrap_err(), ConfigError::BadPort);
        assert_eq!(Endpoint::parse("collector:4318").unwrap_err(), ConfigError::NotAnEndpoint);
        assert_eq!(Endpoint::parse("http://collector").unwrap().port(), 4318);
    }

    #[test]
    fn the_grant_is_checked_per_request() {
        let cfg = OtlpConfig::new("http://127.0.0.1:4318").expect("cfg");
        let exporter = OtlpExporter::new(cfg, Recorder::new(200));
        assert!(exporter.check_url("http://127.0.0.1:4318/v1/traces").is_ok());
        assert_eq!(exporter.check_url("http://127.0.0.1:9999/v1/traces"), Err("destination_not_granted".to_string()));
        assert_eq!(exporter.check_url("http://evil.example/v1/traces"), Err("destination_not_granted".to_string()));
        assert_eq!(exporter.check_url("https://127.0.0.1:4318/v1/traces"), Err("scheme_not_http".to_string()));
    }

    #[test]
    fn export_groups_by_signal_and_reports_success() {
        let transport = std::sync::Arc::new(Recorder::new(200));
        let cfg = OtlpConfig::new("http://127.0.0.1:4318").expect("cfg").with_service("wa-node");
        let exporter = OtlpExporter::new(cfg, SharedRecorder(transport.clone()));
        let outcome = exporter.export(&records(), 1_700_000_001_000);
        assert!(outcome.is_ok(), "{outcome:?}");
        assert_eq!(outcome.requests, 3);
        assert_eq!(outcome.requests_ok, 3);
        let posts = transport.bodies();
        let paths: Vec<&str> = posts.iter().map(|(url, _)| url.as_str()).collect();
        assert_eq!(paths, vec!["http://127.0.0.1:4318/v1/traces", "http://127.0.0.1:4318/v1/metrics", "http://127.0.0.1:4318/v1/logs"]);
        let traces = &posts[0].1;
        assert!(traces.starts_with("{\"resourceSpans\""), "{traces}");
        assert!(traces.contains("\"traceId\":\"4bf92f3577b34da6a3ce929d0e0e4736\""), "{traces}");
        assert!(traces.contains("\"startTimeUnixNano\":\"1700000000000000000\""), "{traces}");
        assert!(traces.contains("\"endTimeUnixNano\":\"1700000000084000000\""), "{traces}");
        assert!(traces.contains("\"status\":{\"code\":2}"), "{traces}");
        let metrics = &posts[1].1;
        assert!(metrics.contains("\"sum\":{\"aggregationTemporality\":2,\"isMonotonic\":true,\"dataPoints\""), "{metrics}");
        assert!(metrics.contains("\"asInt\":\"7\""), "{metrics}");
        let logs = &posts[2].1;
        assert!(logs.contains("\"severityNumber\":13"), "{logs}");
        assert!(logs.contains("\"body\":{\"stringValue\":\"whatsapp.transcript.ready\"}"), "{logs}");
        assert!(logs.contains("\"intValue\":\"2\""), "{logs}");
        assert!(!logs.contains("a long human sentence"), "the digest, not the text: {logs}");
    }

    #[test]
    fn export_splits_at_max_batch_and_counts_failures() {
        let transport = std::sync::Arc::new(Recorder::new(503));
        let mut cfg = OtlpConfig::new("http://127.0.0.1:4318").expect("cfg");
        cfg.max_batch = 1;
        let exporter = OtlpExporter::new(cfg, SharedRecorder(transport.clone()));
        let many: Vec<Record> = (0..3).map(|index| Record::event("t.a", "s", "sch", index)).collect();
        let outcome = exporter.export(&many, 1);
        assert_eq!(outcome.requests, 3, "one request per record with max_batch = 1");
        assert_eq!(outcome.requests_failed, 3);
        assert_eq!(outcome.first_error.as_deref(), Some("http_503"));
        assert!(!outcome.is_ok());
    }

    #[test]
    fn transport_errors_are_redacted_and_short() {
        struct Failing;
        impl Transport for Failing {
            fn post(&self, _url: &str, _ct: &str, _body: &[u8], _t: Duration) -> Result<u16, String> {
                Err("connect_failed token=supersecretvalue123".to_string())
            }
        }
        let cfg = OtlpConfig::new("http://127.0.0.1:4318").expect("cfg");
        let exporter = OtlpExporter::new(cfg, Failing);
        let outcome = exporter.export(&records(), 1);
        let error = outcome.first_error.expect("an error");
        assert!(!error.contains("supersecretvalue123"), "{error}");
        assert!(error.len() <= 97, "{error}");
    }

    #[test]
    fn tcp_transport_refuses_what_it_cannot_do() {
        let transport = TcpTransport;
        assert_eq!(transport.post("https://127.0.0.1:4318/v1/traces", "application/json", b"{}", Duration::from_millis(50)), Err("scheme_not_http".to_string()));
        assert!(transport.post("http://127.0.0.1:1/v1/traces", "application/json", b"{}", Duration::from_millis(200)).is_err());
    }

    // `Arc<Recorder>` is a transport too, so one recorder can be inspected by the test afterwards.
    struct SharedRecorder(std::sync::Arc<Recorder>);
    impl Transport for SharedRecorder {
        fn post(&self, url: &str, content_type: &str, body: &[u8], timeout: Duration) -> Result<u16, String> {
            self.0.post(url, content_type, body, timeout)
        }
    }

    #[test]
    fn stamps_and_payloads_cover_an_empty_batch() {
        let cfg = OtlpConfig::new("http://127.0.0.1:4318").expect("cfg");
        assert_eq!(payload(Signal::Traces, &[], &cfg, 0), "{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"wa-node\"}}]},\"scopeSpans\":[{\"scope\":{\"name\":\"wa-telemetry-sink\",\"version\":\"0.1.0\"},\"spans\":[]}]}]}");
        assert_eq!(stamp(0), "1970-01-01T00:00:00.000Z");
    }
}
