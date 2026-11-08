//! What one mesh decision costs, on each path: p50/p95 per call and the process's resident set.
//!
//! The measurement the split has to answer for (`docs/CORE-SPLIT.md`, "Cost"): `WA_MESH_COMPONENT=1`
//! puts a `wa:mesh` call between the node and the rule it used to run in-process, and a fleet's
//! decisions are per *peer call*, not per turn. So this measures the whole routed call — the request the
//! seam builds, the guest, the answer — and the native call it replaces, scenario for scenario.
//!
//! It is `#[ignore]`d on purpose: a benchmark is not a test, and a suite that silently measures nothing
//! is worse than one that says "ignored". `scripts/bench-mesh.sh` runs it twice, once per path (RSS is a
//! property of the process, and the switch is a process variable), and prints both.
//!
//! Honest limits: this is a loopback-free, node-free measurement in one process — no socket, no relay, no
//! scheduler. A real peer call's wall clock is dominated by the network; the number here is the part the
//! seam adds to the *decision*, which is what the split changed.
use std::time::Instant;

use crate::identity::generate;
use crate::policy::MeshPolicy;
use crate::roster::Draft;
use crate::testkit;

/// One scenario's samples, in microseconds.
struct Samples {
    scenario: &'static str,
    micros: Vec<f64>,
}

impl Samples {
    fn new(scenario: &'static str) -> Samples {
        Samples { scenario, micros: Vec::new() }
    }

    fn time(&mut self, work: impl FnOnce()) {
        let started = Instant::now();
        work();
        self.micros.push(started.elapsed().as_secs_f64() * 1e6);
    }

    fn percentile(&self, percent: usize) -> f64 {
        if self.micros.is_empty() {
            return 0.0;
        }
        let mut sorted = self.micros.clone();
        sorted.sort_by(|left, right| left.partial_cmp(right).unwrap_or(std::cmp::Ordering::Equal));
        let index = ((sorted.len() - 1) * percent / 100).min(sorted.len() - 1);
        sorted[index]
    }

    fn report(&self, path: &str) {
        println!(
            "{path}\t{}\tp50={:.1}us\tp95={:.1}us\tn={}",
            self.scenario,
            self.percentile(50),
            self.percentile(95),
            self.micros.len()
        );
    }
}

/// Resident set of this process, in KB, when the platform exposes it (`/proc`, i.e. Linux and WSL). Git
/// Bash on Windows has `/proc/self/status` but no peak field, so a *sampler* is used: a monitor thread
/// reads `VmRSS` every few milliseconds while the measurement runs, and the largest value is the peak.
struct Rss {
    stop: std::sync::Arc<std::sync::atomic::AtomicBool>,
    peak_kb: std::sync::Arc<std::sync::atomic::AtomicU64>,
    monitor: Option<std::thread::JoinHandle<()>>,
}

/// The resident set of this process, in KB, from the one place the platform keeps it.
fn current_rss_kb() -> Option<u64> {
    if let Some(kb) = proc_rss_kb() {
        return Some(kb);
    }
    windows_peak_rss_kb()
}

/// `/proc/self/status`'s `VmRSS` (Linux and WSL).
fn proc_rss_kb() -> Option<u64> {
    let status = std::fs::read_to_string("/proc/self/status").ok()?;
    for line in status.lines() {
        if let Some(rest) = line.strip_prefix("VmRSS:") {
            return rest.split_whitespace().next().and_then(|value| value.parse().ok());
        }
    }
    None
}

/// The kernel's own peak working set on Windows (`PROCESS_MEMORY_COUNTERS.PeakWorkingSetSize`), which is
/// the number an operator's task manager shows as "peak commit". Declared here rather than pulled in
/// with a dependency: it is a benchmark's one struct, and a crate for it would be a crate in the node's
/// dependency graph for a measurement.
#[cfg(windows)]
fn windows_peak_rss_kb() -> Option<u64> {
    #[repr(C)]
    #[derive(Default)]
    struct MemoryCounters {
        cb: u32,
        page_fault_count: u32,
        peak_working_set_size: usize,
        working_set_size: usize,
        quota_peak_paged_pool_usage: usize,
        quota_paged_pool_usage: usize,
        quota_peak_non_paged_pool_usage: usize,
        quota_non_paged_pool_usage: usize,
        pagefile_usage: usize,
        peak_pagefile_usage: usize,
    }
    #[link(name = "kernel32")]
    extern "system" {
        fn GetCurrentProcess() -> isize;
    }
    #[link(name = "psapi")]
    extern "system" {
        fn K32GetProcessMemoryInfo(process: isize, counters: *mut MemoryCounters, cb: u32) -> i32;
    }
    let mut counters = MemoryCounters { cb: std::mem::size_of::<MemoryCounters>() as u32, ..Default::default() };
    // SAFETY: the struct is the size the call is told about, and it outlives the call.
    let ok = unsafe { K32GetProcessMemoryInfo(GetCurrentProcess(), &mut counters, counters.cb) };
    if ok == 0 {
        return None;
    }
    Some((counters.peak_working_set_size / 1024) as u64)
}

#[cfg(not(windows))]
fn windows_peak_rss_kb() -> Option<u64> {
    None
}

impl Rss {
    fn start() -> Rss {
        use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
        use std::sync::Arc;
        let stop = Arc::new(AtomicBool::new(false));
        let peak = Arc::new(AtomicU64::new(current_rss_kb().unwrap_or(0)));
        let monitor = if current_rss_kb().is_none() {
            None
        } else {
            let (stop, peak) = (stop.clone(), peak.clone());
            Some(std::thread::spawn(move || {
                while !stop.load(Ordering::Relaxed) {
                    if let Some(kb) = current_rss_kb() {
                        peak.fetch_max(kb, Ordering::Relaxed);
                    }
                    std::thread::sleep(std::time::Duration::from_millis(5));
                }
            }))
        };
        Rss { stop, peak_kb: peak, monitor }
    }

    /// The largest sample this run took. `None` on a platform with no resident-set source, so the report
    /// says `n/a` instead of a zero that looks like a measurement.
    fn peak(&self) -> Option<u64> {
        self.monitor.as_ref()?;
        self.stop.store(true, std::sync::atomic::Ordering::Relaxed);
        Some(self.peak_kb.load(std::sync::atomic::Ordering::Relaxed))
    }
}

impl Drop for Rss {
    fn drop(&mut self) {
        self.stop.store(true, std::sync::atomic::Ordering::Relaxed);
        if let Some(monitor) = self.monitor.take() {
            let _ = monitor.join();
        }
    }
}

/// The decision this benchmark times: a fleet of four nodes, one grant, one revocation, and the two
/// verbs a caller actually uses.
#[test]
#[ignore = "benchmark: run via scripts/bench-mesh.sh (one process per path, because RSS is per process)"]
fn mesh_seam_cost() {
    let path = if crate::seam::enabled() { "component" } else { "native" };
    let rss = Rss::start();

    let key = testkit::fleet_key();
    let roster = Draft {
        fleet: "ohana".into(),
        issued_at: 1_762_000_000,
        expires_at: 0,
        nodes: vec![
            testkit::node("laptop", 0, &["192.168.1.10:8891"]),
            testkit::node("oracle", 1, &["147.15.64.233:8891"]),
            testkit::node("phone", 1, &[]),
            testkit::node("guest", 2, &[]),
        ],
    }
    .sign(&key);
    let policy = MeshPolicy::empty();
    let now = 1_762_000_100u64;
    let document = serde_json::to_string(&roster).expect("encode");
    let (_text, identity) = generate().expect("identity");
    let ts = 1_762_000_000u64;
    let signature = identity.sign(&wa_mesh_core::attest::message(&identity.node_id, "8c11", "read", "sessions", "ab12", ts));

    let (laptop, oracle, guest) = (&roster.nodes[0], &roster.nodes[1], &roster.nodes[3]);
    let mut decide_allow = Samples::new("decide_allow(down, control)");
    let mut decide_deny = Samples::new("decide_deny(up, control)");
    let mut verify = Samples::new("verify_roster(4 nodes)");
    let mut audit = Samples::new("render_audit(allow)");
    let mut addresses = Samples::new("addresses(1 roster + 2 learned)");
    let mut message = Samples::new("attest_message");
    let mut ticket = Samples::new("verify_ticket(fresh)");

    let mut cache = crate::cache::PeerCache::empty();
    cache.merge_roster(&roster, 1_762_000_000);
    cache.record_success(&oracle.node_id, "10.0.0.4:8891", 1_762_000_100);
    cache.record_success(&oracle.node_id, "8.8.8.8:8891", 1_762_000_100);

    // Warm-up: the first call pays the compile (once per artifact) and the instance. That cost is
    // reported by the script as a separate line, not folded into p50.
    let cold = Instant::now();
    let _ = crate::seam::decide(&policy, laptop, oracle, crate::hierarchy::Verb::Control, now);
    let cold_ms = cold.elapsed().as_secs_f64() * 1e3;
    println!("{path}\tfirst_call(compile+instance)\t{cold_ms:.1}ms");

    for _ in 0..2_000 {
        decide_allow.time(|| {
            let verdict = crate::seam::decide(&policy, laptop, oracle, crate::hierarchy::Verb::Control, now);
            assert!(verdict.is_allow());
        });
    }
    for _ in 0..2_000 {
        decide_deny.time(|| {
            let verdict = crate::seam::decide(&policy, oracle, laptop, crate::hierarchy::Verb::Control, now);
            assert!(!verdict.is_allow());
        });
    }
    for _ in 0..3 {
        verify.time(|| {
            let parsed = crate::roster::Roster::parse(&document).expect("parse");
            crate::seam::verify_roster(&parsed, &key.public_key, now).expect("verify");
        });
    }
    // The seam's `verify_roster` takes the parsed document (the node has one already); the *signature*
    // check is what a component call adds, so it is measured on its own too.
    let mut verify_only = Samples::new("verify_roster signature only (parsed once)");
    let parsed = crate::roster::Roster::parse(&document).expect("parse");
    for _ in 0..20 {
        verify_only.time(|| {
            crate::seam::verify_roster(&parsed, &key.public_key, now).expect("verify");
        });
    }
    for _ in 0..2_000 {
        audit.time(|| {
            let line = crate::seam::render_audit(
                &crate::audit::Event::new("call", &laptop.node_id, &oracle.node_id)
                    .levels(Some(0), Some(1))
                    .verb("control")
                    .verdict("allow", "hierarchy_allowed")
                    .transport("direct:lan", "private")
                    .outcome(true, Some(200), 41, 1),
            );
            assert!(line.starts_with("mesh call "));
        });
    }
    for _ in 0..2_000 {
        addresses.time(|| {
            let addresses = crate::seam::addresses(&cache, oracle);
            assert!(!addresses.is_empty());
        });
    }
    for _ in 0..2_000 {
        message.time(|| {
            let composed = crate::seam::attest_message(&identity.node_id, "8c11", "read", "sessions", "ab12", ts);
            assert!(!composed.is_empty());
        });
    }
    for _ in 0..500 {
        ticket.time(|| {
            let bound = crate::seam::verify_attestation(
                &identity.public_key,
                &identity.node_id,
                "8c11",
                "read",
                "sessions",
                "ab12",
                ts,
                &signature,
                ts + 5,
            );
            assert!(bound.is_ok(), "{bound:?}");
        });
    }

    // A refusal is a decision too: a roster edited after signing costs a signature check that fails.
    let tampered = testkit::tampered(roster.clone(), &key);
    let tampered_document = serde_json::to_string(&tampered).expect("encode");
    let tampered_parsed = crate::roster::Roster::parse(&tampered_document).expect("parse");
    let mut refusal = Samples::new("verify_roster(tampered) refusal");
    for _ in 0..20 {
        refusal.time(|| {
            assert!(crate::seam::verify_roster(&tampered_parsed, &key.public_key, now).is_err());
        });
    }

    for samples in [
        &decide_allow,
        &decide_deny,
        &verify,
        &verify_only,
        &audit,
        &addresses,
        &message,
        &ticket,
        &refusal,
    ] {
        samples.report(path);
    }
    match rss.peak() {
        Some(kb) => println!("{path}\tpeak_rss\t{kb}KB"),
        None => println!("{path}\tpeak_rss\tn/a (no /proc on this platform)"),
    }
    // The guest's own death is not this test's subject; what the seam reported is.
    println!("{path}\tfallbacks\t{:?}", crate::seam::fallbacks());
    let _ = guest;
}
