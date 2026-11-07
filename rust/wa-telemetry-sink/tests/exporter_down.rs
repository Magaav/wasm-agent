//! The exporter check: a collector that is refusing, then healthy, then gone.
//!
//! Three properties, in the order they matter:
//!
//! 1. a dead collector never makes the buffer grow past its bound (the producer keeps working);
//! 2. the loss is counted (`otlp_failed`, `otlp_dropped`) and the local JSONL file still has every
//!    record, because the file is the record;
//! 3. when the collector comes back the next flush succeeds and `otlp_recovered` says so.
//!
//! The collector is a real socket on 127.0.0.1 that speaks HTTP/1.1, so `TcpTransport` is exercised
//! for real: request line, Host, Content-Length, body, status parsing.
use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::atomic::{AtomicBool, AtomicU16, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use wa_telemetry_sink::buffer::Bounds;
use wa_telemetry_sink::record::{EventRecord, Id, Record, Severity};
use wa_telemetry_sink::sink::{Config, Sink};

/// A minimal OTLP collector: accepts one request per connection, answers `status`, counts requests.
struct Collector {
    port: u16,
    stop: Arc<AtomicBool>,
    requests: Arc<AtomicU64>,
    status: Arc<AtomicU16>,
    handle: Option<std::thread::JoinHandle<()>>,
}

impl Collector {
    fn start(initial_status: u16) -> Collector {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        listener.set_nonblocking(true).expect("nonblocking");
        let port = listener.local_addr().expect("addr").port();
        let stop = Arc::new(AtomicBool::new(false));
        let requests = Arc::new(AtomicU64::new(0));
        let status = Arc::new(AtomicU16::new(initial_status));
        let handle = {
            let stop = stop.clone();
            let requests = requests.clone();
            let status = status.clone();
            std::thread::spawn(move || {
                while !stop.load(Ordering::Relaxed) {
                    match listener.accept() {
                        Ok((mut stream, _)) => {
                            let _ = stream.set_nonblocking(false);
                            let _ = stream.set_read_timeout(Some(Duration::from_millis(500)));
                            let mut head = Vec::new();
                            let mut buffer = [0u8; 512];
                            while !head.windows(4).any(|window| window == b"\r\n\r\n") {
                                match stream.read(&mut buffer) {
                                    Ok(0) | Err(_) => break,
                                    Ok(read) => head.extend_from_slice(&buffer[..read]),
                                }
                                if head.len() > 64 << 10 {
                                    break;
                                }
                            }
                            let text = String::from_utf8_lossy(&head).to_string();
                            let length = text
                                .lines()
                                .find_map(|line| {
                                    let (name, value) = line.split_once(':')?;
                                    if name.eq_ignore_ascii_case("content-length") {
                                        value.trim().parse::<usize>().ok()
                                    } else {
                                        None
                                    }
                                })
                                .unwrap_or(0);
                            let mut body = Vec::new();
                            if let Some(index) = head.windows(4).position(|window| window == b"\r\n\r\n") {
                                body.extend_from_slice(&head[index + 4..]);
                            }
                            while body.len() < length {
                                match stream.read(&mut buffer) {
                                    Ok(0) | Err(_) => break,
                                    Ok(read) => body.extend_from_slice(&buffer[..read]),
                                }
                            }
                            requests.fetch_add(1, Ordering::Relaxed);
                            let code = status.load(Ordering::Relaxed);
                            let response = format!(
                                "HTTP/1.1 {code} {}\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{{}}",
                                if code == 200 { "OK" } else { "Unavailable" }
                            );
                            let _ = stream.write_all(response.as_bytes());
                        }
                        Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                            std::thread::sleep(Duration::from_millis(2));
                        }
                        Err(_) => break,
                    }
                }
            })
        };
        Collector { port, stop, requests, status, handle: Some(handle) }
    }

    fn endpoint(&self) -> String {
        format!("http://127.0.0.1:{}", self.port)
    }

    fn set_status(&self, code: u16) {
        self.status.store(code, Ordering::Relaxed);
    }

    fn requests(&self) -> u64 {
        self.requests.load(Ordering::Relaxed)
    }

    fn shutdown(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
    }
}

impl Drop for Collector {
    fn drop(&mut self) {
        self.shutdown();
    }
}

fn event(index: u64) -> Record {
    Record::Event(EventRecord {
        topic: Id::new("node.test.event"),
        source: Id::new("wa-host"),
        schema: Id::new("wa.node.test"),
        schema_version: 1,
        ts_ms: 1_700_000_000_000 + index,
        count: 1,
        severity: Severity::Info,
        trace: None,
        attrs: Default::default(),
    })
}

fn tempdir(tag: &str) -> std::path::PathBuf {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let dir = std::env::temp_dir().join(format!("wa-sink-down-{tag}-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed)));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

fn sink_for(dir: &std::path::Path, endpoint: String, capacity: usize) -> Sink {
    let mut config = Config {
        bounds: Bounds { max_records: capacity, ..Bounds::default() },
        batch_records: 128,
        jsonl: None,
        otlp: None,
    }
    .with_jsonl(dir);
    config.otlp = Some(wa_telemetry_sink::OtlpConfig::new(&endpoint).expect("endpoint"));
    Sink::open(config).expect("open sink")
}

#[test]
fn a_refusing_collector_never_grows_the_buffer_and_the_file_still_has_the_record() {
    let collector = Collector::start(503);
    let dir = tempdir("refusing");
    let capacity = 128;
    let sink = sink_for(&dir, collector.endpoint(), capacity);

    // A burst with no flush: the bound is the buffer's, not the collector's.
    for index in 0..2_000u64 {
        sink.record(event(index));
    }
    assert_eq!(sink.queued().0, capacity);
    assert_eq!(sink.stats().telemetry_dropped, 2_000 - capacity as u64);

    // Flush into a collector that refuses. Every batch is counted; nothing accumulates behind it.
    let mut pumped_records = 0usize;
    for _ in 0..40 {
        let report = sink.pump();
        pumped_records += report.drained;
        if report.drained == 0 {
            break;
        }
        assert_eq!(report.otlp_requests_failed, 1, "one failed request per flush");
        assert!(report.otlp_error.as_deref().map(|error| error.starts_with("http_503")).unwrap_or(false));
        assert!(sink.queued().0 <= capacity, "the buffer stays bounded while the collector is down");
    }
    assert_eq!(pumped_records, capacity);
    let stats = sink.stats();
    assert!(stats.otlp_failed >= 1, "{stats:?}");
    assert_eq!(stats.otlp_dropped, pumped_records as u64, "each refused batch is counted once");
    assert_eq!(stats.telemetry_dropped, 2_000 - capacity as u64, "an OTLP loss is not a buffer loss");
    assert_eq!(stats.jsonl_rows, pumped_records as u64, "the local file has every exported record");
    assert!(collector.requests() >= 1);

    // Recovery: the same endpoint, now healthy.
    collector.set_status(200);
    sink.record(event(9_999));
    let started = Instant::now();
    let report = sink.pump();
    assert_eq!(report.otlp_requests_ok, 1, "{report:?}");
    assert!(started.elapsed() < Duration::from_secs(5));
    let stats = sink.stats();
    assert_eq!(stats.otlp_recovered, 1, "the transition back to healthy is counted once");
    assert_eq!(stats.otlp_sent, 1);

    // The file is readable and complete: one JSON object per exported record, no message text.
    let path = sink.jsonl_path().expect("jsonl path");
    let text = std::fs::read_to_string(path).expect("read jsonl");
    let rows: Vec<&str> = text.lines().collect();
    assert_eq!(rows.len(), pumped_records + 1);
    for row in &rows {
        assert!(row.starts_with('{') && row.ends_with('}'));
        assert!(row.contains("\"kind\":\"event\""));
        assert!(row.contains("\"topic\":\"node.test.event\""));
        assert!(!row.contains('\n'));
    }
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_collector_that_is_gone_costs_a_counted_error_and_no_unbounded_wait() {
    // Bind, note the port, drop the listener: connecting is refused, exactly like a stopped collector.
    let port = {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        listener.local_addr().expect("addr").port()
    };
    let dir = tempdir("gone");
    let sink = sink_for(&dir, format!("http://127.0.0.1:{port}"), 64);
    for index in 0..200u64 {
        sink.record(event(index));
    }
    let started = Instant::now();
    let report = sink.pump();
    let elapsed = started.elapsed();
    assert_eq!(report.drained, 64);
    assert_eq!(report.otlp_requests_failed, 1);
    let error = report.otlp_error.expect("an error");
    assert!(error.starts_with("connect_failed"), "{error}");
    // The transport's timeout (2 s default) is the ceiling for one attempt; no retry loop.
    assert!(elapsed < Duration::from_secs(10), "one flush took {elapsed:?}");
    assert_eq!(sink.queued().0, 0, "the batch left the buffer; the failure was counted instead");
    let stats = sink.stats();
    assert_eq!(stats.otlp_failed, 1);
    assert_eq!(stats.otlp_dropped, 64);
    assert_eq!(stats.error_hits, 1);
    assert!(stats.last_error_ms > 0);
    let _ = std::fs::remove_dir_all(&dir);
}
