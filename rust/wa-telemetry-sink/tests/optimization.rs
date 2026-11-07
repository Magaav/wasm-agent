//! The optimization check the job asks for: producer latency and RSS before vs after, with the sink
//! on, plus what the exporter side costs. Numbers are printed (run with `--nocapture`); the
//! assertions only refuse a bound being exceeded, because a CI machine is not a benchmark rig.
//!
//! Method:
//!
//! * the **before** pass builds and drops the same record the node builds today (a span/metric/event
//!   struct), with no sink in the process;
//! * the **after** pass does the same and hands the record to a live sink whose JSONL edge is on a
//!   temp directory — the real configuration, not a stub;
//! * RSS is the process's resident set from `measure::rss_bytes` (Windows `K32GetProcessMemoryInfo`,
//!   Linux `/proc/self/statm`), taken after a warmup, after the burst, and after the flush;
//! * the buffer's own worst case (`Bounds::worst_case_bytes`) is the analytic bound the measured
//!   delta is compared against.
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;

use wa_telemetry_sink::buffer::Bounds;
use wa_telemetry_sink::measure::rss_bytes;
use wa_telemetry_sink::record::{Attr, Attrs, Id, MetricKind, MetricRecord, Record, SpanStatus, Unit};
use wa_telemetry_sink::sink::{Config, Sink};
use wa_telemetry_sink::JsonlConfig;

const BURST: usize = 10_000;
const CAPACITY: usize = 4_096;

fn record(index: u64) -> Record {
    if index.is_multiple_of(2) {
        Record::Span(wa_telemetry_sink::record::SpanRecord {
            component: Id::new("wa-whatsapp"),
            op: Id::new("transcribe"),
            start_ms: 1_700_000_000_000 + index,
            duration_us: 84_000,
            status: SpanStatus::Ok,
            trace: None,
            attrs: Attrs::from(vec![Attr::id("status", "ok"), Attr::count("bytes", 4_096)]),
        })
    } else {
        Record::Metric(MetricRecord {
            component: Id::new("wa-host"),
            name: Id::new("op_duration_micros"),
            kind: MetricKind::Gauge,
            unit: Unit::Micros,
            value: 84_000,
            labels: Attrs::from(vec![Attr::id("op", "run")]),
        })
    }
}

fn percentiles(mut samples: Vec<u64>) -> (u64, u64, u64, u64) {
    samples.sort_unstable();
    let at = |permille: usize| samples[(samples.len() - 1) * permille / 1000];
    let mean = samples.iter().sum::<u64>() / samples.len() as u64;
    (at(500), at(990), *samples.last().expect("samples"), mean)
}

fn tempdir(tag: &str) -> std::path::PathBuf {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let dir = std::env::temp_dir().join(format!("wa-sink-opt-{tag}-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed)));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

#[test]
fn producer_latency_and_rss_before_and_after_the_sink() {
    // Warm the allocator and the code paths so the "before" RSS is not the first-touch number.
    for index in 0..2_000u64 {
        std::hint::black_box(record(index));
    }
    let rss_warm = rss_bytes();

    // --- before: no sink ---------------------------------------------------------------------
    let mut before = Vec::with_capacity(BURST);
    for index in 0..BURST as u64 {
        let started = Instant::now();
        let built = record(index);
        std::hint::black_box(&built);
        before.push(started.elapsed().as_nanos() as u64);
    }
    std::hint::black_box(before.len());
    let rss_before = rss_bytes();
    let mut before_samples = Vec::with_capacity(BURST);
    for index in 0..BURST as u64 {
        let started = Instant::now();
        let built = record(index);
        std::hint::black_box(&built);
        before_samples.push(started.elapsed().as_nanos() as u64);
    }
    let (before_p50, before_p99, before_max, before_mean) = percentiles(before_samples);

    // --- after: a live sink, JSONL edge on, buffer of CAPACITY -------------------------------
    let dir = tempdir("after");
    let bounds = Bounds { max_records: CAPACITY, ..Bounds::default() };
    let mut config = Config { bounds, batch_records: 256, jsonl: None, otlp: None };
    config.jsonl = Some(JsonlConfig { dir: dir.clone(), prefix: "telemetry".to_string(), max_bytes: 1 << 20, max_files: 4 });
    let sink = Sink::open(config).expect("open sink");

    let mut after = Vec::with_capacity(BURST);
    for index in 0..BURST as u64 {
        let started = Instant::now();
        let kept = sink.record(record(index));
        std::hint::black_box(kept);
        after.push(started.elapsed().as_nanos() as u64);
    }
    let (after_p50, after_p99, after_max, after_mean) = percentiles(after);
    let rss_after_burst = rss_bytes();
    assert_eq!(sink.queued().0, CAPACITY);
    assert_eq!(sink.stats().telemetry_dropped as usize, BURST - CAPACITY);

    // --- exporter side: what the flush costs, off the producer's path ------------------------
    let flush_started = Instant::now();
    let report = sink.flush();
    let flush_elapsed = flush_started.elapsed();
    let rss_after_flush = rss_bytes();
    assert_eq!(report.drained, CAPACITY);
    assert_eq!(report.jsonl_rows, CAPACITY);

    let mib = |bytes: Option<u64>| bytes.map(|bytes| bytes as f64 / (1024.0 * 1024.0));
    println!(
        "optimization: burst={BURST} capacity={CAPACITY} \
         producer_ns before p50={before_p50} p99={before_p99} mean={before_mean} max={before_max} | \
         after p50={after_p50} p99={after_p99} mean={after_mean} max={after_max} | \
         delta_mean_ns={} delta_p50_ns={} delta_p99_ns={}",
        after_mean as i64 - before_mean as i64,
        after_p50 as i64 - before_p50 as i64,
        after_p99 as i64 - before_p99 as i64,
    );
    println!(
        "optimization: rss_mib warm={:?} before={:?} after_burst={:?} after_flush={:?} delta_burst={:?} bound={:?}",
        mib(rss_warm),
        mib(rss_before),
        mib(rss_after_burst),
        mib(rss_after_flush),
        mib(rss_after_burst.zip(rss_before).map(|(after, before)| after.saturating_sub(before))),
        mib(Some(bounds.worst_case_bytes() as u64)),
    );
    println!(
        "optimization: flush records={} jsonl_rows={} rows_lost={} elapsed_ms={} ns_per_record={}",
        report.drained,
        report.jsonl_rows,
        report.jsonl_lost,
        flush_elapsed.as_millis(),
        flush_elapsed.as_nanos() as usize / report.drained.max(1),
    );

    // The measured RSS growth must be inside the buffer's own analytic bound (plus a small margin for
    // the writer, the file handle and allocator slack) — if it is not, the budget is a comment.
    if let (Some(before), Some(after)) = (rss_before, rss_after_burst) {
        let grown = after.saturating_sub(before);
        let bound = bounds.worst_case_bytes() as u64 + (8 << 20);
        assert!(grown <= bound, "rss grew {grown} bytes, bound is {bound}");
    }

    // A latency order-of-magnitude regression is refused; the printed numbers are the evidence.
    assert!(after_p99 <= before_p99.saturating_mul(8) + 20_000, "p99 regressed: {before_p99} -> {after_p99} ns");
    assert!(after_mean <= before_mean.saturating_mul(8) + 2_000, "mean regressed: {before_mean} -> {after_mean} ns");
    let _ = std::fs::remove_dir_all(&dir);
}
