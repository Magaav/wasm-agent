//! The node's telemetry registry, wired (docs/TELEMETRY.md "Where the host records").
//!
//! One [`Metrics`] per node process, restored from `<state>/telemetry/registry.bin` on start and
//! saved back on a timer. The registry is a library with no thread of its own, so this module owns
//! the two things the crate deliberately leaves to the host: the clock tick and the snapshot file
//! (inside the bounded `<state>/telemetry/` directory, `store.rs`).
//!
//! What the host records, and where:
//!
//! | call site | record |
//! | --- | --- |
//! | `components::run` (one MCP/request run) | `record_component_run` → `op_total{op="run"}`, `op_duration_micros{op="run"}`, a sampled span |
//! | every `wa:kernel` host call (`service_components.rs`) | `record_host_call` → `host_call_total{capability,status}`, `host_call_duration_micros{capability}`, a sampled span |
//! | the service supervisor (`services.rs`) | `record_service_health` (gauge), `record_service_restart` (counter), one `run` op per service run |
//! | the ticker below | `tick()` once a second, snapshot every 5 minutes, `store::sweep` + `node_policy::tick` every minute |
//!
//! Names and labels are closed sets (a capability string, a service name, an outcome word): nothing
//! here can invent a label value per message, so the cardinality caps in the crate are never the
//! thing that saves us. Message text never reaches this module.
use serde_json::{json, Value};
use std::sync::OnceLock;
use std::time::{Duration, SystemTime};
use wa_telemetry::{Config, Metrics, Span, SpanStatus};

/// The ticker's period: cheap when nothing happened (docs/TELEMETRY.md).
const TICK: Duration = Duration::from_secs(1);
/// The registry snapshot's period. It contains the trace ring, so this is not a per-second write.
const SNAPSHOT_EVERY: u64 = 300;
/// Bounded-store sweep and policy tick period.
const SWEEP_EVERY: u64 = 60;
/// The largest text `host.telemetry` hands to Lua: a scrape is not a data dump, and the Lua
/// boundary is not a place to push tens of megabytes.
const MAX_TEXT: usize = 256 << 10;

pub(crate) fn now_ms() -> u64 {
    SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

struct Node {
    metrics: Metrics,
}

fn node() -> &'static Node {
    static NODE: OnceLock<Node> = OnceLock::new();
    NODE.get_or_init(|| {
        let metrics = Metrics::new(Config::default());
        // Unit tests get a plain in-process registry: no snapshot is read and no ticker thread is
        // spawned, so a test can never depend on (or write to) a real node's home. The pieces the
        // ticker drives are tested directly (`store::sweep`, `Metrics::save`).
        #[cfg(not(test))]
        {
            let snapshot = crate::store::telemetry_snapshot();
            if snapshot.is_file() {
                if let Err(error) = metrics.load(&snapshot) {
                    eprintln!("[telemetry] {}: {error} (starting with a fresh registry)", snapshot.display());
                }
            }
            let ticker = metrics.clone();
            let spawned = std::thread::Builder::new().name("wa-telemetry-tick".into()).spawn(move || {
                let mut ticks: u64 = 0;
                loop {
                    std::thread::sleep(TICK);
                    ticks += 1;
                    ticker.tick();
                    if ticks.is_multiple_of(SWEEP_EVERY) {
                        let _ = crate::store::sweep(SystemTime::now());
                        crate::node_policy::tick();
                    }
                    if ticks.is_multiple_of(SNAPSHOT_EVERY) {
                        save(&ticker, &snapshot);
                    }
                }
            });
            if let Err(error) = spawned {
                eprintln!("[telemetry] ticker unavailable ({error}); metrics are live but not rolled up or saved");
            }
        }
        Node { metrics }
    })
}

/// One process-wide counter so the ticker's period does not have to be split into three threads.
/// Write the registry into the bounded telemetry directory, refusing (visibly) when the store is
/// full: a snapshot is worth less than the store it lives in.
fn save(metrics: &Metrics, path: &std::path::Path) {
    match crate::store::telemetry_dir() {
        Ok(dir) => match dir.usage() {
            Ok(usage) if usage.over_quota() => {
                eprintln!(
                    "[telemetry] snapshot refused: telemetry store at {} bytes of a {} byte quota",
                    usage.bytes, usage.quota
                );
                return;
            }
            _ => {}
        },
        Err(error) => {
            eprintln!("[telemetry] snapshot refused: telemetry store unavailable: {error}");
            return;
        }
    }
    if let Err(error) = metrics.save(path) {
        eprintln!("[telemetry] snapshot failed: {error}");
    }
}

/// One in-flight `wa:kernel` host call.
///
/// `Drop` records it, so a host call that returns early - every `let … else { return Err(…) }` in
/// `service_components.rs` - is still a recorded call, and recorded as a failure, which is exactly
/// what an early return from a `Result`-returning host function is. Nothing is recorded twice: one
/// guard per call.
pub struct HostCallGuard {
    component: String,
    interface: &'static str,
    started: std::time::Instant,
    ok: bool,
}

impl HostCallGuard {
    pub fn start(component: &str, interface: &'static str) -> HostCallGuard {
        HostCallGuard { component: component.to_string(), interface, started: std::time::Instant::now(), ok: false }
    }

    /// Mark the outcome of the call.
    pub fn outcome<T, E>(&mut self, result: &Result<T, E>) {
        self.ok = result.is_ok();
    }

    /// For the host calls that cannot fail (a lifecycle report, closing a resource).
    pub fn succeed(&mut self) {
        self.ok = true;
    }
}

impl Drop for HostCallGuard {
    fn drop(&mut self) {
        record_host_call(&self.component, self.interface, self.started.elapsed().as_micros() as u64, self.ok);
    }
}

/// The node's registry. Cheap to clone; every handle records into the same state.
pub fn metrics() -> &'static Metrics {
    &node().metrics
}

/// One component call (a run, an MCP request, a service iteration).
pub fn record_component_run(component: &str, start_ms: u64, duration_us: u64, ok: bool) {
    record_run_on(metrics(), component, start_ms, duration_us, ok);
}

pub(crate) fn record_run_on(metrics: &Metrics, component: &str, start_ms: u64, duration_us: u64, ok: bool) {
    metrics.record_op(component, "run", start_ms, duration_us, if ok { SpanStatus::Ok } else { SpanStatus::Error });
}

/// One host call, attributed to the calling component and labelled by capability. `capability` is a
/// closed set (the `wa:kernel` function names), so the label cannot grow with traffic.
pub fn record_host_call(component: &str, capability: &str, duration_us: u64, ok: bool) {
    record_host_call_on(metrics(), component, capability, duration_us, ok);
}

pub(crate) fn record_host_call_on(metrics: &Metrics, component: &str, capability: &str, duration_us: u64, ok: bool) {
    let status = if ok { SpanStatus::Ok } else { SpanStatus::Error };
    metrics
        .histogram(component, "host_call_duration_micros")
        .observe_labeled(duration_us, ok, &[("capability", capability)]);
    metrics
        .counter(component, "host_call_total")
        .add_labeled(1, &[("capability", capability), ("status", status.as_str())]);
    metrics.record_span(Span::new(component, capability, metrics.now_ms(), duration_us, status));
}

/// 1 while a service runs, 0 once it is stopped: the one number that says "the WhatsApp channel is
/// up" without reading a log.
pub fn record_service_health(service: &str, running: bool) {
    record_service_health_on(metrics(), service, running);
}

pub(crate) fn record_service_health_on(metrics: &Metrics, service: &str, running: bool) {
    metrics
        .gauge("wa-kernel", "service_health")
        .set_labeled(if running { 1 } else { 0 }, &[("service", service), ("instance", "0")]);
}

/// Why a service was restarted. `reason` is a closed set: `exit`, `trap`, `error`, `start`, `stop`.
pub fn record_service_restart(service: &str, reason: &str) {
    metrics()
        .counter("wa-kernel", "service_restart_total")
        .add_labeled(1, &[("service", service), ("reason", reason)]);
}

/// The closed set a supervisor outcome maps to (`services.rs`), so the label cannot carry text.
pub fn restart_reason(outcome: &str) -> &'static str {
    if outcome.starts_with("exit_") {
        "exit"
    } else if outcome.starts_with("trap:") {
        "trap"
    } else if outcome.starts_with("service_error:") {
        "error"
    } else if outcome.starts_with("compile_failed") || outcome.starts_with("instantiate_failed") || outcome.starts_with("link_failed") || outcome.starts_with("log_unavailable") || outcome.starts_with("no_start_export") {
        "start"
    } else if outcome == "stopped" {
        "stop"
    } else {
        "other"
    }
}

fn request_format(raw: &str) -> String {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return "json".into();
    }
    if trimmed.starts_with('{') {
        return serde_json::from_str::<Value>(trimmed)
            .ok()
            .and_then(|value| value.get("format").and_then(Value::as_str).map(str::to_string))
            .unwrap_or_else(|| "json".into());
    }
    trimmed.to_string()
}

/// What `host.telemetry` answers, as text. Formats: `prometheus`, `json` (default), `stats`,
/// `rollups`, `traces`, `store`.
pub fn answer(raw: &str) -> String {
    let metrics = metrics();
    let format = request_format(raw);
    let text = match format.as_str() {
        "prometheus" => metrics.prometheus(),
        "rollups" => metrics.rollups_json().to_string(),
        "traces" => metrics.traces_json().to_string(),
        "stats" => serde_json::to_string(&json!({
            "stats": stats_json(metrics),
            "store": crate::store::usage_report(),
        })).unwrap_or_else(|_| "{}".into()),
        "store" => crate::store::usage_report().to_string(),
        _ => serde_json::to_string(&json!({
            "stats": stats_json(metrics),
            "registry": metrics.to_json(),
            "store": crate::store::usage_report(),
            "policy": crate::node_policy::status_summary(),
            "snapshot": {
                "path": crate::store::telemetry_snapshot().to_string_lossy(),
                "exists": crate::store::telemetry_snapshot().is_file(),
            },
        })).unwrap_or_else(|_| "{}".into()),
    };
    cap(text)
}

fn stats_json(metrics: &Metrics) -> Value {
    let stats = metrics.stats();
    json!({
        "components": stats.components,
        "families": stats.families,
        "series": stats.series,
        "kind_conflicts": stats.kind_conflicts,
        "dropped_components": stats.dropped_components,
        "dropped_families": stats.dropped_families,
        "rollup_series": stats.rollup_series,
        "rollup_refused": stats.rollup_refused,
        "sample_permille": metrics.sample_permille(),
        "trace": {
            "spans": stats.trace.spans,
            "bytes": stats.trace.bytes,
            "max_bytes": stats.trace.max_bytes,
            "kept": stats.trace.kept,
            "sampled_out": stats.trace.sampled_out,
            "evicted": stats.trace.evicted,
            "oversized": stats.trace.oversized,
            "attrs_dropped": stats.trace.attrs_dropped,
            "attrs_truncated": stats.trace.attrs_truncated,
        },
    })
}

/// Truncate at a UTF-8 boundary and say so: a silent truncation would read as complete data.
fn cap(mut text: String) -> String {
    if text.len() <= MAX_TEXT {
        return text;
    }
    let mut end = MAX_TEXT;
    while end > 0 && !text.is_char_boundary(end) {
        end -= 1;
    }
    text.truncate(end);
    text.push_str("\n# truncated at 256 KiB; ask for a narrower format (stats, store, rollups, traces)\n");
    text
}

/// `host.telemetry(request_json_or_format)` -> one text answer (Prometheus or JSON).
pub extern "C-unwind" fn capability(l: *mut crate::lua::LuaState) -> std::os::raw::c_int {
    let raw = crate::lua::arg_string(l, 1).unwrap_or_default();
    let text = answer(&raw);
    unsafe {
        crate::lua::lua_pushlstring(l, text.as_ptr() as *const std::os::raw::c_char, text.len());
    }
    1
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_metrics() -> Metrics {
        Metrics::new(Config::for_tests())
    }

    #[test]
    fn a_component_run_is_one_counter_and_one_latency_series() {
        let metrics = test_metrics();
        record_run_on(&metrics, "svc-echo", 1_000, 4_000, true);
        record_run_on(&metrics, "svc-echo", 2_000, 9_000, false);
        assert_eq!(metrics.counter("svc-echo", "op_total").get(&[("op", "run"), ("status", "ok")]), Some(1));
        assert_eq!(metrics.counter("svc-echo", "op_total").get(&[("op", "run"), ("status", "error")]), Some(1));
        let view = metrics.histogram("svc-echo", "op_duration_micros").get(&[("op", "run")]).expect("run series exists");
        assert_eq!(view.count, 2);
        assert_eq!(view.max, 9_000);
    }

    #[test]
    fn a_host_call_is_labelled_by_capability_not_by_target() {
        let metrics = test_metrics();
        record_host_call_on(&metrics, "wa-whatsapp", "kv.set", 120, true);
        record_host_call_on(&metrics, "wa-whatsapp", "kv.set", 80, false);
        assert_eq!(metrics.counter("wa-whatsapp", "host_call_total").get(&[("capability", "kv.set"), ("status", "ok")]), Some(1));
        assert_eq!(metrics.counter("wa-whatsapp", "host_call_total").get(&[("capability", "kv.set"), ("status", "error")]), Some(1));
        let view = metrics.histogram("wa-whatsapp", "host_call_duration_micros").get(&[("capability", "kv.set")]).expect("series");
        assert_eq!(view.count, 2);
        assert_eq!(view.sum, 200);
    }

    #[test]
    fn service_health_is_a_gauge_and_a_restart_reason_is_a_closed_set() {
        let metrics = test_metrics();
        record_service_health_on(&metrics, "wa-whatsapp", true);
        assert_eq!(metrics.gauge("wa-kernel", "service_health").get(&[("service", "wa-whatsapp"), ("instance", "0")]), Some(1));
        record_service_health_on(&metrics, "wa-whatsapp", false);
        assert_eq!(metrics.gauge("wa-kernel", "service_health").get(&[("service", "wa-whatsapp"), ("instance", "0")]), Some(0));
        assert_eq!(restart_reason("exit_3"), "exit");
        assert_eq!(restart_reason("trap:wasm trap: unreachable"), "trap");
        assert_eq!(restart_reason("service_error:bad config"), "error");
        assert_eq!(restart_reason("instantiate_failed:x"), "start");
        assert_eq!(restart_reason("stopped"), "stop");
        assert_eq!(restart_reason("something else entirely"), "other");
    }

    #[test]
    fn the_formats_are_asked_for_by_name_and_an_empty_request_is_json() {
        assert_eq!(request_format(""), "json");
        assert_eq!(request_format("prometheus"), "prometheus");
        assert_eq!(request_format(r#"{"format":"rollups"}"#), "rollups");
        assert_eq!(request_format(r#"{"nonsense":1}"#), "json");
        // A very large answer is capped, not silently cut.
        let text = cap("x".repeat(MAX_TEXT + 10));
        assert!(text.ends_with("narrower format (stats, store, rollups, traces)\n"));
        assert!(text.len() < MAX_TEXT + 200);
    }
}
