//! Burst check: 10 000 events through the producer path, with and without a sink.
//!
//! The claim under test is not "the sink is free" — it is "the producer's cost does not change
//! because a sink exists". So both loops do the same work (build a record), and only one hands it to
//! the sink. Percentiles are taken over the per-record samples; the numbers are printed with
//! `--nocapture` and are the ones REPORT.md quotes.
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;

use wa_telemetry_sink::buffer::Bounds;
use wa_telemetry_sink::record::{Attr, Attrs, EventRecord, Id, Record, Severity};
use wa_telemetry_sink::sink::{Config, Sink};
use wa_telemetry_sink::TcpTransport;

const BURST: usize = 10_000;
const CAPACITY: usize = 256;

fn event(index: u64) -> Record {
    Record::Event(EventRecord {
        topic: Id::new("whatsapp.transcript.ready"),
        source: Id::new("wa-whatsapp"),
        schema: Id::new("wa.whatsapp.transcript"),
        schema_version: 1,
        ts_ms: 1_700_000_000_000 + index,
        count: 1,
        severity: Severity::Info,
        trace: None,
        attrs: Attrs::from(vec![Attr::id("status", "ok"), Attr::count("bytes", 4_096)]),
    })
}

fn percentiles(mut samples: Vec<u64>) -> (u64, u64, u64) {
    samples.sort_unstable();
    let at = |permille: usize| samples[(samples.len() - 1) * permille / 1000];
    (at(500), at(990), *samples.last().expect("samples"))
}

fn tempdir(tag: &str) -> std::path::PathBuf {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let dir = std::env::temp_dir().join(format!("wa-sink-burst-{tag}-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed)));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

/// Producer-only: build the record and let it go, exactly what the node does today with a span.
fn without_sink() -> Vec<u64> {
    let mut samples = Vec::with_capacity(BURST);
    for index in 0..BURST as u64 {
        let started = Instant::now();
        let record = event(index);
        std::hint::black_box(&record);
        samples.push(started.elapsed().as_nanos() as u64);
    }
    samples
}

fn with_sink(sink: &Sink<TcpTransport>) -> Vec<u64> {
    let mut samples = Vec::with_capacity(BURST);
    for index in 0..BURST as u64 {
        let started = Instant::now();
        let record = event(index);
        let kept = sink.record(record);
        std::hint::black_box(kept);
        samples.push(started.elapsed().as_nanos() as u64);
    }
    samples
}

#[test]
fn a_ten_thousand_event_burst_keeps_the_producer_cost_and_counts_the_drops() {
    // Warm up both paths (first-touch allocation, branch predictor, the mutex's first lock).
    let warmup = Sink::open(Config { bounds: Bounds { max_records: CAPACITY, ..Bounds::default() }, batch_records: 64, jsonl: None, otlp: None })
        .expect("open sink");
    for index in 0..1_000u64 {
        std::hint::black_box(warmup.record(event(index)));
    }
    drop(warmup);

    let dir = tempdir("latency");
    let sink = Sink::open(Config { bounds: Bounds { max_records: CAPACITY, ..Bounds::default() }, batch_records: 64, jsonl: Some(wa_telemetry_sink::JsonlConfig::new(&dir)), otlp: None })
        .expect("open sink");

    let base = without_sink();
    let sunk = with_sink(&sink);
    let (base_p50, base_p99, base_max) = percentiles(base);
    let (p50, p99, max) = percentiles(sunk);

    println!(
        "burst={BURST} capacity={CAPACITY} producer_ns baseline p50={base_p50} p99={base_p99} max={base_max} | with_sink p50={p50} p99={p99} max={max}"
    );

    // Back-pressure is a count, not a stall: the buffer kept the newest CAPACITY and said so.
    let stats = sink.stats();
    assert_eq!(sink.queued().0, CAPACITY);
    assert_eq!(stats.accepted as usize, BURST);
    assert_eq!(stats.telemetry_dropped as usize, BURST - CAPACITY);
    assert_eq!(stats.oversized, 0);

    // The producer's own work dominates; the sink adds one mutex, one length check and a push.
    // The bound is deliberately loose (CI machines, a debug build) because the *measurement* above is
    // the evidence and this assertion only refuses an order-of-magnitude regression.
    assert!(p50 <= base_p50 * 8 + 1_000, "p50 regressed: {base_p50} -> {p50} ns");
    assert!(p99 <= base_p99 * 8 + 20_000, "p99 regressed: {base_p99} -> {p99} ns");

    // The exporter side drains what survived and the JSONL rows equal the kept records.
    let report = sink.flush();
    assert_eq!(report.drained, CAPACITY);
    assert_eq!(report.jsonl_rows, CAPACITY);
    assert_eq!(sink.queued().0, 0);
    assert_eq!(sink.stats().telemetry_dropped as usize, BURST - CAPACITY, "a flush does not change the drop count");
    let _ = std::fs::remove_dir_all(&dir);
}
