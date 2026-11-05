//! Unit tests for the guarantees the crate claims: bounded storage, honest counts, boundary
//! behaviour under an injected clock.
use crate::clock::manual;
use crate::config::Config;
use crate::metrics::Metrics;
use crate::queue::QueueMetrics;
use crate::rollup::{DAY_MS, HOUR_MS, MINUTE_MS};
use crate::trace::{sample_hash, Keep, Sampler, Span, SpanStatus};
use std::time::Duration;

fn metrics(cfg: Config, start_ms: u64) -> (Metrics, crate::clock::ManualClock) {
    let (clk, clock) = manual(start_ms);
    (Metrics::with_clock(cfg, clock), clk)
}

fn base_ms() -> u64 {
    DAY_MS * 10 + HOUR_MS * 5 + MINUTE_MS * 7
}

#[test]
fn histogram_records_buckets_and_percentiles() {
    let (m, _) = metrics(Config::default(), base_ms());
    let h = m.histogram("wa-whisper", "transcribe_micros");
    for _ in 0..50 {
        h.observe(20_000, true);
    }
    for _ in 0..50 {
        h.observe(900_000, false);
    }
    let view = h.get(&[]).expect("series exists");
    assert_eq!(view.count, 100);
    assert_eq!(view.sum, 50 * 20_000 + 50 * 900_000);
    assert_eq!(view.min, 20_000);
    assert_eq!(view.max, 900_000);
    // The estimate is inside the bucket that holds the true value (±1 bucket width).
    let p50 = view.p50.unwrap();
    let p95 = view.p95.unwrap();
    assert!((19_000..=21_500).contains(&p50), "p50 {p50}");
    assert!((850_000..=950_000).contains(&p95), "p95 {p95}");
    // Bucket counts add up to the sample count.
    assert_eq!(view.buckets.iter().sum::<u64>(), 100);
    // Errors are a separate rollup number, not a separate histogram.
    assert_eq!(m.stats().series, 1);
}

#[test]
fn rollups_roll_over_minute_hour_and_day_boundaries() {
    let (m, clk) = metrics(Config::for_tests(), base_ms());
    let h = m.histogram("svc", "op_micros");
    let minute0 = (base_ms() / MINUTE_MS) as u32;
    let hour0 = (base_ms() / HOUR_MS) as u32;
    let day0 = (base_ms() / DAY_MS) as u32;

    h.observe(1_000, true);
    h.observe(3_000, false); // 2 observations, one error, in minute 0
    clk.advance_secs(60);
    h.observe(2_000, true); // minute 1
    m.tick();

    let v = &m.rollups()[0];
    assert_eq!(v.minutes.len(), 1, "minute 0 is closed, minute 1 is open");
    assert_eq!(v.minutes[0].start_ms, minute0 as u64 * MINUTE_MS);
    assert_eq!(v.minutes[0].observations, 2);
    assert_eq!(v.minutes[0].errors, 1);
    assert_eq!(v.minutes[0].sum, 4_000);
    assert_eq!(v.minutes[0].min, 1_000);
    assert_eq!(v.minutes[0].max, 3_000);
    assert_eq!(v.current.observations, 1);
    assert!(v.hours.is_empty(), "the hour is not closed yet");

    // Cross the hour: the hour cell is the sum of the minutes it holds.
    clk.advance_secs(3_600);
    h.observe(5_000, true);
    m.tick();
    let v = &m.rollups()[0];
    assert_eq!(v.minutes.len(), 2);
    assert_eq!(v.hours.len(), 1);
    assert_eq!(v.hours[0].start_ms, hour0 as u64 * HOUR_MS);
    assert_eq!(v.hours[0].observations, 3);
    assert_eq!(v.hours[0].sum, 6_000);
    assert_eq!(v.hours[0].errors, 1);
    assert!(v.days.is_empty());

    // Cross the day.
    clk.advance_secs(24 * 3_600);
    h.observe(7_000, true);
    m.tick();
    let v = &m.rollups()[0];
    assert_eq!(v.days.len(), 1);
    assert_eq!(v.days[0].start_ms, day0 as u64 * DAY_MS);
    assert_eq!(v.days[0].observations, 4);
    assert_eq!(v.days[0].sum, 11_000);
    assert_eq!(v.hours.len(), 2, "the crossed hour was closed too");
    assert_eq!(v.hours.iter().map(|p| p.observations).sum::<u64>(), 4);
}

#[test]
fn rollup_rings_keep_the_newest_buckets() {
    let (m, clk) = metrics(Config::for_tests(), base_ms());
    let h = m.counter("svc", "events");
    for i in 0..6u64 {
        h.add(1);
        if i < 5 {
            clk.advance_secs(60);
        }
    }
    clk.advance_secs(60);
    m.tick(); // closes the last minute
    let v = &m.rollups()[0];
    assert_eq!(v.minutes.len(), 4, "minute_slots is 4 in the test config");
    let starts: Vec<u64> = v.minutes.iter().map(|p| p.start_ms).collect();
    let mut sorted = starts.clone();
    sorted.sort_unstable();
    assert_eq!(starts, sorted, "oldest first");
    let expected_last = ((base_ms() + 5 * MINUTE_MS) / MINUTE_MS) * MINUTE_MS;
    assert_eq!(*starts.last().unwrap(), expected_last);
    assert_eq!(
        (expected_last - starts[0]) / MINUTE_MS,
        3,
        "the newest four minutes survive a ring of four"
    );
}

#[test]
fn cardinality_cap_folds_into_one_other_series() {
    let (m, _) = metrics(Config::for_tests(), base_ms());
    let c = m.counter("svc", "events");
    c.add_labeled(1, &[("chat", "a")]);
    c.add_labeled(2, &[("chat", "b")]);
    c.add_labeled(4, &[("chat", "c")]); // over the cap of 2
    c.add_labeled(8, &[("chat", "c")]); // same overflow set again
    assert_eq!(c.get(&[("chat", "a")]), Some(1));
    assert_eq!(c.get(&[("chat", "b")]), Some(2));
    // Both overflowed observations fold into the single `wa_other` series.
    let other = c.get(&[("wa_other", "1")]).expect("other series exists");
    assert_eq!(other, 12);
    assert_eq!(m.stats().series, 3, "two named series plus one other");
    let text = m.prometheus();
    assert_eq!(text.matches("wa_other=\"1\"").count(), 1);
    assert!(text.contains("wa_telemetry_cardinality_dropped"));
}

#[test]
fn family_and_label_caps_are_visible() {
    let mut cfg = Config::for_tests();
    cfg.max_families_per_component = 2;
    let (m, _) = metrics(cfg, base_ms());
    for name in ["a", "b", "c", "d"] {
        m.counter("svc", name).inc();
    }
    let stats = m.stats();
    assert_eq!(stats.families, 2);
    assert_eq!(stats.dropped_families, 2);
    let text = m.prometheus();
    assert!(text.contains("wa_telemetry_refused_total{reason=\"family\"} 2"));
}

#[test]
fn kind_conflict_is_refused_and_counted() {
    let (m, _) = metrics(Config::default(), base_ms());
    m.counter("svc", "ops").inc();
    m.histogram("svc", "ops").observe(1_000, true);
    let stats = m.stats();
    assert_eq!(stats.kind_conflicts, 1);
    assert_eq!(stats.families, 1);
    let text = m.prometheus();
    assert!(text.contains("# TYPE ops counter"));
    assert!(!text.contains("# TYPE ops histogram"));
    assert!(text.contains("wa_telemetry_kind_conflicts_total 1"));
}

#[test]
fn sampler_keeps_errors_and_slow_spans_and_samples_the_rest() {
    let mut cfg = Config::for_tests();
    cfg.trace_sample_permille = 20; // 2%
    cfg.trace_slow_us = 1_000;
    cfg.set_slow_us("svc", "transcribe", 500);
    let sampler = Sampler::new(&cfg);

    let normal = Span::new("svc", "handle", 0, 100, SpanStatus::Ok).with_trace_id(1);
    assert_eq!(sampler.decide(&normal), Keep::Dropped);
    let error = Span::new("svc", "handle", 0, 100, SpanStatus::Error).with_trace_id(2);
    assert_eq!(sampler.decide(&error), Keep::Error);
    let slow = Span::new("svc", "handle", 0, 1_001, SpanStatus::Ok).with_trace_id(3);
    assert_eq!(sampler.decide(&slow), Keep::Slow);
    // The per-op threshold wins over the default one.
    let op_slow = Span::new("svc", "transcribe", 0, 600, SpanStatus::Ok).with_trace_id(4);
    assert_eq!(sampler.decide(&op_slow), Keep::Slow);
    let op_fast = Span::new("svc", "transcribe", 0, 400, SpanStatus::Ok).with_trace_id(5);
    assert_eq!(sampler.decide(&op_fast), Keep::Dropped);
    // Expired is an error for sampling purposes.
    let expired = Span::new("svc", "handle", 0, 10, SpanStatus::Expired).with_trace_id(6);
    assert_eq!(sampler.decide(&expired), Keep::Error);

    // Determinism: the same span identity always gets the same answer.
    for id in 0..64u64 {
        let span = Span::new("svc", "handle", 0, 10, SpanStatus::Ok).with_trace_id(id);
        assert_eq!(sampler.decide(&span), sampler.decide(&span.clone()));
        assert_eq!(sample_hash("svc", "handle", id), sample_hash("svc", "handle", id));
    }

    // Rate: over many identities the kept share is near the configured 2%.
    let keep = (0..10_000u64)
        .filter(|id| {
            sampler.decide(&Span::new("svc", "handle", 0, 10, SpanStatus::Ok).with_trace_id(*id))
                == Keep::Sampled
        })
        .count();
    assert!((50..350).contains(&keep), "kept {keep} of 10000 at 2%");
}

#[test]
fn trace_ring_evicts_oldest_first_and_stays_under_cap() {
    let mut cfg = Config::for_tests();
    cfg.trace_bytes = 200;
    cfg.trace_sample_permille = 1000;
    let (m, _) = metrics(cfg, base_ms());
    for id in 1..=20u64 {
        let span = Span::new("svc", "handle", base_ms(), 10, SpanStatus::Ok).with_trace_id(id);
        m.record_span(span);
    }
    let stats = m.stats().trace;
    assert!(stats.bytes <= stats.max_bytes, "{} <= {}", stats.bytes, stats.max_bytes);
    assert!(stats.evicted > 0, "the ring must evict rather than grow");
    let kept: Vec<u64> = m.spans().iter().map(|s| s.trace_id).collect();
    assert!(!kept.is_empty());
    assert!(*kept.last().unwrap() == 20, "the newest span is present");
    assert!(!kept.contains(&1), "the oldest span is gone");
    assert!(kept.windows(2).all(|w| w[0] < w[1]), "oldest first: {kept:?}");
}

#[test]
fn sample_rate_zero_and_full_are_honoured() {
    let mut cfg = Config::for_tests();
    cfg.trace_sample_permille = 0;
    let (m, _) = metrics(cfg, base_ms());
    assert!(!m.record_span(Span::new("svc", "handle", 0, 1, SpanStatus::Ok)));
    assert_eq!(m.stats().trace.sampled_out, 1);
    // Errors are still kept at rate 0.
    assert!(m.record_span(Span::new("svc", "handle", 0, 1, SpanStatus::Error)));

    let mut cfg = Config::for_tests();
    cfg.trace_sample_permille = 1000;
    let (m, _) = metrics(cfg, base_ms());
    for _ in 0..5 {
        assert!(m.record_span(Span::new("svc", "handle", 0, 1, SpanStatus::Ok)));
    }
    assert_eq!(m.stats().trace.spans, 5);
}

#[test]
fn record_op_writes_histogram_counter_and_span() {
    let (m, _) = metrics(Config::default(), base_ms());
    m.record_op("wa-whatsapp", "transcribe", base_ms(), 600_000, SpanStatus::Ok);
    let hist = m
        .histogram("wa-whatsapp", "op_duration_micros")
        .get(&[("op", "transcribe")])
        .expect("histogram series");
    assert_eq!(hist.count, 1);
    assert_eq!(hist.sum, 600_000);
    let c = m.counter("wa-whatsapp", "op_total");
    assert_eq!(c.get(&[("op", "transcribe"), ("status", "ok")]), Some(1));
    // A slow op is kept by the sampler even at 2%.
    let spans = m.spans();
    assert_eq!(spans.len(), 1);
    assert_eq!(spans[0].op.as_ref(), "transcribe");
    assert_eq!(spans[0].status, SpanStatus::Ok);
    assert_eq!(spans[0].duration_us, 600_000);
}

#[test]
fn span_timer_measures_and_records() {
    let (m, _) = metrics(Config::default(), base_ms());
    let timer = m.start_span("svc", "work").attr("lane", "audio");
    std::thread::sleep(Duration::from_millis(2));
    let kept = timer.finish(SpanStatus::Error);
    assert!(kept, "an error span is always kept");
    let spans = m.spans();
    assert_eq!(spans.len(), 1);
    assert!(spans[0].duration_us >= 1_000, "{}", spans[0].duration_us);
    assert_eq!(spans[0].attrs, vec![("lane".to_string(), "audio".to_string())]);
    let c = m.counter("svc", "op_total");
    assert_eq!(c.get(&[("op", "work"), ("status", "error")]), Some(1));
}

#[test]
fn gauge_accepts_negative_values_and_add() {
    let (m, _) = metrics(Config::default(), base_ms());
    let g = m.gauge("svc", "queue_pending");
    g.set(3);
    assert_eq!(g.get(&[]), Some(3));
    g.add(-5);
    assert_eq!(g.get(&[]), Some(-2));
    g.add_labeled(1, &[("queue", "audio")]);
    assert_eq!(g.get(&[("queue", "audio")]), Some(1));
}

#[test]
fn queue_lifecycle_records_wait_run_failures_and_expiries() {
    let (m, clk) = metrics(Config::default(), base_ms());
    let q = QueueMetrics::new(m.clone(), "wa-whatsapp", "audio");

    q.enqueued(1, "transcribe");
    clk.advance_secs(2);
    q.started(1, "transcribe");
    clk.advance_secs(3);
    q.done(1, "transcribe");

    q.enqueued(2, "transcribe");
    clk.advance_ms(500);
    q.started(2, "transcribe");
    q.failed(2, "transcribe", "decode_error");

    q.enqueued(3, "transcribe");
    clk.advance_secs(300);
    q.expired(3, "transcribe", "stale_over_5m");

    let wait = m
        .histogram("wa-whatsapp", "queue_wait_micros")
        .get(&[("queue", "audio"), ("job", "transcribe")])
        .expect("wait histogram");
    assert_eq!(wait.count, 2);
    assert!(wait.max >= 2_000_000, "the 2 s wait is measured: {}", wait.max);

    let run = m
        .histogram("wa-whatsapp", "queue_run_micros")
        .get(&[("queue", "audio"), ("job", "transcribe")])
        .expect("run histogram");
    assert_eq!(run.count, 2);
    assert!(run.max >= 3_000_000);

    let failed = m.counter("wa-whatsapp", "queue_failed_total");
    assert_eq!(failed.get(&[("queue", "audio"), ("job", "transcribe"), ("reason", "decode_error")]), Some(1));
    let expired = m.counter("wa-whatsapp", "queue_expired_total");
    assert_eq!(
        expired.get(&[("queue", "audio"), ("job", "transcribe"), ("reason", "stale_over_5m")]),
        Some(1)
    );
    assert_eq!(q.depth(), 0);
    assert_eq!(m.gauge("wa-whatsapp", "queue_pending").get(&[("queue", "audio")]), Some(0));
    // Errors and the expiry are in the trace ring; the two normal jobs are not sampled at 2%
    // unless they were slow, so at least the error and expiry spans must be there.
    let statuses: Vec<SpanStatus> = m.spans().iter().map(|s| s.status).collect();
    assert!(statuses.contains(&SpanStatus::Error), "{statuses:?}");
    assert!(statuses.contains(&SpanStatus::Expired), "{statuses:?}");
}

#[test]
fn snapshot_round_trips_metrics_rollups_and_spans() {
    let cfg = Config::default();
    let (m, clk) = metrics(cfg.clone(), base_ms());
    m.counter("svc", "events").add_labeled(7, &[("kind", "a")]);
    m.gauge("svc", "depth").set(-3);
    let h = m.histogram("svc", "op_micros");
    h.observe(1_500, true);
    h.observe(90_000, false);
    clk.advance_secs(60);
    h.observe(2_500, true);
    m.tick();
    m.record_span(Span::new("svc", "op", base_ms(), 90_000, SpanStatus::Error).with_trace_id(42));

    let bytes = m.snapshot_bytes();
    let before_text = m.prometheus();
    let before_traces = m.traces_json();

    let (m2, _) = metrics(cfg, base_ms() + 60_000);
    m2.restore_bytes(&bytes).expect("restores");
    assert_eq!(m2.prometheus(), before_text);
    assert_eq!(m2.traces_json(), before_traces);
    assert_eq!(m2.rollups_json(), m.rollups_json());
    // The restored registry keeps working (the series and its rollup link are re-established).
    m2.counter("svc", "events").add_labeled(1, &[("kind", "a")]);
    assert_eq!(
        m2.counter("svc", "events").get(&[("kind", "a")]),
        Some(8)
    );
    assert_eq!(m2.stats().rollup_series, 3);
    assert_eq!(m2.snapshot_bytes().len(), bytes.len());
}

#[test]
fn snapshot_rejects_foreign_or_truncated_input() {
    let (m, _) = metrics(Config::default(), base_ms());
    m.counter("svc", "events").inc();
    assert!(m.restore_bytes(b"not a snapshot at all").is_err());
    let bytes = m.snapshot_bytes();
    let cut = &bytes[..bytes.len() / 2];
    assert!(m.restore_bytes(cut).is_err());
    // A bad version is named, not guessed.
    let mut wrong = bytes.clone();
    wrong[8] = 9;
    match m.restore_bytes(&wrong) {
        Err(crate::SnapshotError::BadVersion(9)) => {}
        other => panic!("expected BadVersion, got {other:?}"),
    }
}

#[test]
fn snapshot_save_is_atomic_and_load_reads_it_back() {
    let dir = std::env::var_os("CARGO_TARGET_DIR")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    std::fs::create_dir_all(&dir).expect("target dir");
    let path = dir.join(format!("wa-telemetry-test-{}.snap", std::process::id()));
    let (m, _) = metrics(Config::default(), base_ms());
    m.counter("svc", "events").inc();
    m.save(&path).expect("saves");
    assert!(path.exists());
    assert!(
        !path.with_file_name(format!("{}.tmp", path.file_name().unwrap().to_string_lossy())).exists(),
        "the temp file is renamed away, not left behind"
    );
    let (m2, _) = metrics(Config::default(), base_ms());
    m2.load(&path).expect("loads");
    assert_eq!(m2.counter("svc", "events").get(&[]), Some(1));
    let _ = std::fs::remove_file(&path);
}

#[test]
fn prometheus_and_json_export_cover_every_kind() {
    let (m, _) = metrics(Config::default(), base_ms());
    m.counter("wa-whatsapp", "op_total").add_labeled(2, &[("status", "ok")]);
    m.gauge("wa-whatsapp", "queue_pending").set_labeled(1, &[("queue", "audio")]);
    m.histogram("wa-whatsapp", "op_duration_micros").observe_labeled(1_000, true, &[("op", "transcribe")]);

    let text = m.prometheus();
    assert!(text.contains("# TYPE op_total counter"));
    assert!(text.contains("op_total{component=\"wa-whatsapp\",status=\"ok\"} 2"));
    assert!(text.contains("# TYPE queue_pending gauge"));
    assert!(text.contains("# TYPE op_duration_micros histogram"));
    assert!(text.contains("op_duration_micros_bucket{component=\"wa-whatsapp\",op=\"transcribe\",le=\""));
    assert!(text.contains("op_duration_micros_count{component=\"wa-whatsapp\",op=\"transcribe\"} 1"));
    assert!(text.contains("op_duration_micros_sum{component=\"wa-whatsapp\",op=\"transcribe\"} 1000"));
    assert!(text.contains("wa_telemetry_trace{field=\"max_bytes\"}"));

    let json = m.to_json();
    assert_eq!(json["version"], 1);
    assert_eq!(json["stats"]["components"], 1);
    let families = json["components"]["wa-whatsapp"]["families"]
        .as_array()
        .expect("families");
    assert_eq!(families.len(), 3);
    let hist = families
        .iter()
        .find(|f| f["name"] == "op_duration_micros")
        .expect("histogram family");
    assert_eq!(hist["kind"], "histogram");
    assert_eq!(hist["series"][0]["count"], 1);
    assert!(hist["series"][0]["p50"].is_number());
    assert_eq!(m.rollups_json()["rollups"].as_array().unwrap().len(), 3);
    assert_eq!(m.traces_json()["spans"], serde_json::json!([]));
}

#[test]
fn trace_storage_is_absent_from_the_metrics_namespace() {
    // A span never becomes a metric with unbounded labels: only counters/histograms are, and those
    // are capped. Recording 5000 distinct ops must not create 5000 series.
    let (m, _) = metrics(Config::for_tests(), base_ms());
    for i in 0..5_000 {
        m.record_span(
            Span::new("svc", format!("op{i}"), base_ms(), 1, SpanStatus::Ok).with_trace_id(i as u64),
        );
    }
    assert_eq!(m.stats().series, 0, "a span does not register a metric series");
}

#[test]
fn snapshot_from_a_bigger_config_restores_into_a_smaller_one() {
    let (m, _) = metrics(Config::default(), base_ms());
    for i in 0..50 {
        m.counter("svc", &format!("metric{i}")).inc();
    }
    let bytes = m.snapshot_bytes();
    let (m2, _) = metrics(Config::for_tests(), base_ms());
    m2.restore_bytes(&bytes)
        .expect("a snapshot taken with bigger caps still parses");
    // What fits is kept, the rest is dropped by the live caps - not by misreading the file.
    assert_eq!(m2.stats().families, Config::for_tests().max_families_per_component);
    assert!(m2.prometheus().contains("# TYPE metric0 counter"));
}

#[test]
fn counters_and_gauges_are_safe_across_threads() {
    let (m, _) = metrics(Config::default(), base_ms());
    let g = m.gauge("svc", "depth");
    let c = m.counter("svc", "events");
    std::thread::scope(|scope| {
        for _ in 0..4 {
            let g = g.clone();
            let c = c.clone();
            scope.spawn(move || {
                for _ in 0..500 {
                    g.add(1);
                    c.inc();
                }
            });
        }
    });
    assert_eq!(g.get(&[]), Some(2_000));
    assert_eq!(c.get(&[]), Some(2_000));
}

#[test]
fn tick_is_idempotent_and_cheap_when_nothing_happened() {
    let (m, clk) = metrics(Config::default(), base_ms());
    m.counter("svc", "events").inc();
    clk.advance_secs(120);
    m.tick();
    let after_first = m.rollups_json();
    m.tick();
    m.tick();
    assert_eq!(m.rollups_json(), after_first);
    assert_eq!(m.stats().rollup_series, 1);
    assert_eq!(m.stats().rollup_refused, 0);
}

#[test]
fn rollup_cap_refuses_new_series_and_counts_it() {
    let mut cfg = Config::for_tests();
    cfg.rollup_series = 1;
    let (m, _) = metrics(cfg, base_ms());
    m.counter("svc", "a").inc();
    m.counter("svc", "b").inc();
    let stats = m.stats();
    assert_eq!(stats.rollup_series, 1);
    assert_eq!(stats.rollup_refused, 1);
    assert!(m.prometheus().contains("wa_telemetry_refused_total{reason=\"rollup\"} 1"));
}

#[test]
fn per_series_storage_matches_the_documented_bound() {
    // The numbers in docs/TELEMETRY.md are derived from these sizes; a change here must change
    // the doc (and the reviewer should see both in the same patch).
    let slot = std::mem::size_of::<crate::rollup::Slot>();
    let cfg = Config::default();
    let per_series = (cfg.minute_slots + cfg.hour_slots + cfg.day_slots) * slot;
    assert!(slot <= 48, "rollup slot grew to {slot} bytes");
    assert!(
        per_series <= 300 * 1024,
        "rollups for one series cost {per_series} bytes"
    );
    let hist = crate::histogram::bucket_count(Config::default().hist_sub_bits) * std::mem::size_of::<u64>();
    assert!(hist <= 8 * 1024, "one histogram series costs {hist} bytes");
}

