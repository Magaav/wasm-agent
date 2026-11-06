//! Service components on the `wa:kernel` WIT contract (docs/KERNEL.md): the `service-component`
//! world, run by the same supervisor as the wasip1 services (services.rs picks by binary header).
//! The guest imports websocket/http/kv/lifecycle/log/credentials/speech and exports `service.run`.
//!
//! Two layers are enforced here, in this order (`docs/GRANT-POLICY.md`, "How the host wires it"):
//!
//! 1. the **manifest grant** (`Grant`) - may this component reach this address at all;
//! 2. the **node policy** (`node_policy.rs`) - how often, to whom, with what record. A rule the
//!    operator wrote is enforced; a sensitive capability with no rule is refused (`no_policy`) when a
//!    policy file is loaded, while a node with **no** policy file runs in manifest mode, where the
//!    manifest grant above stays the only gate and the decision is audited as `manifest_mode`.
//!
//! Every answered function also records one telemetry observation
//! (`node_telemetry::HostCallGuard`): the latency of the host call, its outcome, a sampled span.
use crate::components::{Grant, Installed};
use crate::node_telemetry::HostCallGuard;
use wa_grant_policy::Decision;
use crate::service_io::{http_start, url_authority, HttpState, Kv as KvStore, WsConn, AGAIN, CLOSED};
use crate::services::{dial_allowed, Shared};
use std::io::Write as _;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use wasmtime::component::{Component, HasSelf, Linker, Resource, ResourceTable};
use wasmtime::{Store, StoreLimits, StoreLimitsBuilder, UpdateDeadline};
use wasmtime_wasi::{WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};

// The native recognizer behind wa:kernel/speech (declared here, not in main.rs). Shared with the
// 0.2 runner: one recognizer hub per process, whichever contract the service speaks.
#[path = "service_stt.rs"]
pub(crate) mod service_stt;

wasmtime::component::bindgen!({
    world: "service-component",
    path: "../../wit/kernel",
    with: {
        "wa:kernel/websocket.socket": WsSocket,
        "wa:kernel/http.pending": HttpPending,
        "wa:kernel/speech.job": SpeechJob,
    },
});

use wa::kernel::types::Error as KError;

/// One open socket and the authority it was granted for. The authority is kept beside the
/// connection because `websocket.send` takes ciphertext: the address is the only target the policy
/// layer can name (`docs/GRANT-POLICY.md`, "The honest gap").
pub struct WsSocket {
    conn: Option<WsConn>,
    authority: String,
}
pub struct HttpPending(HttpState);
pub struct SpeechJob {
    slot: service_stt::JobSlot,
    language: String,
}

pub struct State {
    wasi: WasiCtx,
    table: ResourceTable,
    limits: StoreLimits,
    net: Vec<String>,
    shared: Arc<Shared>,
    kv: KvStore,
    log: Option<std::fs::File>,
    secrets: std::collections::BTreeMap<String, String>,
    /// Manifest `capabilities.stt == true`.
    stt: bool,
    /// The installed name: policy checks and telemetry are attributed to the component, so one
    /// running instance answers "who called this" without a second registry.
    name: String,
}

impl WasiView for State {
    fn ctx(&mut self) -> WasiCtxView<'_> {
        WasiCtxView { ctx: &mut self.wasi, table: &mut self.table }
    }
}

/// The shared store's errors as the kernel's: an undeclared namespace is a refusal (as before),
/// anything else the store reports is a failure.
fn kv_error(error: String) -> KError {
    if error == "storage not declared" {
        KError::Refused(error)
    } else {
        KError::Failed(error)
    }
}

impl wa::kernel::types::Host for State {}

/// Map one policy answer to the guest's error (`docs/GRANT-POLICY.md` "Result mapping"): a rate
/// limit shorter than a second becomes `again`, because the guest already retries that; everything
/// else is a refusal the component can report, and the reason word is the stable one the audit
/// record carries.
fn gate(component: &str, capability: &str, target: Option<&str>) -> Result<(), KError> {
    gate_decision(crate::node_policy::check(component, capability, target))
}

/// The mapping itself, separate so it is testable without a policy file (and so the table in
/// `docs/GRANT-POLICY.md` has one implementation to drift from).
fn gate_decision(decision: Decision) -> Result<(), KError> {
    match decision {
        Decision::Allow => Ok(()),
        Decision::RateLimited { retry_after_ms, .. } if retry_after_ms < 1_000 => Err(KError::Again),
        other => Err(KError::Refused(other.reason_str().to_string())),
    }
}

/// A key as a policy/audit target. Invalid UTF-8 is still a target (lossy), so two requests that
/// name the same bytes share one budget; the audit caps the field at 160 characters.
fn target_of(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

/// A URL authority as a policy target. Host names are case-insensitive (and the manifest grant
/// compares them lowercased, `services::dial_allowed`), so the policy sees the lowercased form: a
/// rule written for `web.whatsapp.com:443` must not be defeated - and must not defeat a working
/// component - because a client emitted `WSS://WEB.WHATSAPP.COM/...`. Patterns are matched case
/// sensitively by the crate, so this is where the two layers are made to agree.
fn authority_target(authority: &str) -> String {
    authority.to_ascii_lowercase()
}

impl wa::kernel::websocket::Host for State {}
impl wa::kernel::websocket::HostSocket for State {
    fn connect(&mut self, url: String, origin: Option<String>) -> Result<Resource<WsSocket>, KError> {
        let mut call = HostCallGuard::start(&self.name, "websocket.connect");
        let out = (|| {
            // Grant first, policy second: a rule can only ever narrow what the manifest allows.
            let authority = url_authority(&url)
                .filter(|addr| dial_allowed(&self.net, addr))
                .ok_or_else(|| KError::Refused(url.clone()))?;
            gate(&self.name, "net.dial", Some(&authority_target(&authority)))?;
            let conn = WsConn::open(&url, origin.as_deref()).map_err(KError::Failed)?;
            self.table.push(WsSocket { conn: Some(conn), authority }).map_err(|e| KError::Failed(e.to_string()))
        })();
        call.outcome(&out);
        out
    }
    fn send(&mut self, socket: Resource<WsSocket>, data: Vec<u8>) -> Result<(), KError> {
        let mut call = HostCallGuard::start(&self.name, "websocket.send");
        let out = (|| {
            let Some(socket) = self.table.get(&socket).ok() else { return Err(KError::Closed) };
            let Some(conn) = socket.conn.as_ref() else { return Err(KError::Closed) };
            let authority = socket.authority.clone();
            // The frame is opaque, so what the host can charge is the authority plus the global
            // message budget, and only for a policy rule that names no chats
            // (`node_policy::check_opaque_send`). The per-chat check needs `wa:channel/messages`.
            match crate::node_policy::check_opaque_send(&self.name, &authority) {
                Decision::Allow => {}
                Decision::RateLimited { retry_after_ms, .. } if retry_after_ms < 1_000 => return Err(KError::Again),
                other => return Err(KError::Refused(other.reason_str().to_string())),
            }
            if conn.send(data) == 0 {
                Ok(())
            } else {
                Err(KError::Closed)
            }
        })();
        call.outcome(&out);
        out
    }
    fn recv(&mut self, socket: Resource<WsSocket>) -> Result<Vec<u8>, KError> {
        let mut call = HostCallGuard::start(&self.name, "websocket.recv");
        let out = (|| {
            let Some(conn) = self.table.get_mut(&socket).ok().and_then(|s| s.conn.as_mut()) else { return Err(KError::Closed) };
            match conn.next() {
                AGAIN => Err(KError::Again),
                CLOSED => Err(KError::Closed),
                _ => conn.take().ok_or(KError::Again),
            }
        })();
        call.outcome(&out);
        out
    }
    fn close(&mut self, socket: Resource<WsSocket>) {
        let mut call = HostCallGuard::start(&self.name, "websocket.close");
        if let Ok(s) = self.table.get_mut(&socket) {
            s.conn = None;
        }
        call.succeed();
    }
    fn drop(&mut self, socket: Resource<WsSocket>) -> wasmtime::Result<()> {
        self.table.delete(socket)?;
        Ok(())
    }
}

impl wa::kernel::http::Host for State {}
impl wa::kernel::http::HostPending for State {
    fn start(&mut self, req: wa::kernel::http::Request) -> Result<Resource<HttpPending>, KError> {
        let mut call = HostCallGuard::start(&self.name, "http.start");
        let out = (|| {
            let authority = url_authority(&req.url)
                .filter(|addr| dial_allowed(&self.net, addr))
                .ok_or_else(|| KError::Refused(req.url.clone()))?;
            gate(&self.name, "http.request", Some(&authority_target(&authority)))?;
            let headers: serde_json::Map<String, serde_json::Value> = req.headers.into_iter().map(|(k, v)| (k, serde_json::Value::String(v))).collect();
            let meta = serde_json::json!({"url": req.url, "method": req.method, "headers": headers});
            let state = http_start(&meta, req.body).map_err(KError::Failed)?;
            self.table.push(HttpPending(state)).map_err(|e| KError::Failed(e.to_string()))
        })();
        call.outcome(&out);
        out
    }
    fn poll(&mut self, pending: Resource<HttpPending>) -> Result<wa::kernel::http::Response, KError> {
        let mut call = HostCallGuard::start(&self.name, "http.poll");
        let out = (|| {
            let p = self.table.get_mut(&pending).map_err(|_| KError::Closed)?;
            match p.0.poll() {
                AGAIN => Err(KError::Again),
                status if status >= 0 => match &p.0 {
                    HttpState::Done(_, body) => Ok(wa::kernel::http::Response { status: status as u16, body: body.clone() }),
                    _ => Err(KError::Failed("no body".into())),
                },
                _ => Err(KError::Failed("exchange failed".into())),
            }
        })();
        call.outcome(&out);
        out
    }
    fn drop(&mut self, pending: Resource<HttpPending>) -> wasmtime::Result<()> {
        self.table.delete(pending)?;
        Ok(())
    }
}

impl wa::kernel::speech::Host for State {}
impl wa::kernel::speech::HostJob for State {
    fn start(&mut self, audio: Vec<u8>, mime: String, language: String) -> Result<Resource<SpeechJob>, KError> {
        let mut call = HostCallGuard::start(&self.name, "speech.start");
        let out = (|| {
            if !self.stt {
                return Err(KError::Refused("stt not declared".into()));
            }
            gate(&self.name, "stt.start", None)?;
            let slot = service_stt::submit(audio, &mime, &language).map_err(KError::Failed)?;
            self.table.push(SpeechJob { slot, language }).map_err(|e| KError::Failed(e.to_string()))
        })();
        call.outcome(&out);
        out
    }
    fn poll(&mut self, job: Resource<SpeechJob>) -> Result<wa::kernel::speech::Transcript, KError> {
        let mut call = HostCallGuard::start(&self.name, "speech.poll");
        let out = (|| {
            let job = self.table.get(&job).map_err(|_| KError::Closed)?;
            let state = job.slot.lock().unwrap().state.clone();
            match state {
                service_stt::JobState::Queued => Err(KError::Again),
                service_stt::JobState::Done { text, elapsed_ms } => {
                    Ok(wa::kernel::speech::Transcript { text, language: job.language.clone(), elapsed_ms })
                }
                service_stt::JobState::Failed(reason) => Err(KError::Failed(reason)),
            }
        })();
        call.outcome(&out);
        out
    }
    fn segments(&mut self, job: Resource<SpeechJob>, from: u32) -> Vec<String> {
        let Ok(job) = self.table.get(&job) else { return Vec::new() };
        job.slot.lock().unwrap().segments.iter().skip(from as usize).cloned().collect()
    }
    fn drop(&mut self, job: Resource<SpeechJob>) -> wasmtime::Result<()> {
        self.table.delete(job)?;
        Ok(())
    }
}

impl wa::kernel::kv::Host for State {
    fn get(&mut self, key: Vec<u8>) -> Result<Option<Vec<u8>>, KError> {
        let mut call = HostCallGuard::start(&self.name, "kv.get");
        let target = target_of(&key);
        let out = (|| {
            gate(&self.name, "kv.read", Some(&target))?;
            self.kv.get(key).map_err(kv_error)
        })();
        call.outcome(&out);
        out
    }
    fn set(&mut self, key: Vec<u8>, value: Vec<u8>) -> Result<(), KError> {
        let mut call = HostCallGuard::start(&self.name, "kv.set");
        let target = target_of(&key);
        let out = (|| {
            // The component's own namespace, but a write is a shadow copy of state: sensitive by
            // default, so a node with a policy file and no rule for it refuses the write with
            // `no_policy` (a node with no policy file runs in manifest mode).
            gate(&self.name, "kv.write", Some(&target))?;
            self.kv.set(key, value).map_err(kv_error)
        })();
        call.outcome(&out);
        out
    }
    fn delete(&mut self, key: Vec<u8>) -> Result<(), KError> {
        let mut call = HostCallGuard::start(&self.name, "kv.delete");
        let target = target_of(&key);
        let out = (|| {
            gate(&self.name, "kv.write", Some(&target))?;
            self.kv.delete(key).map_err(kv_error)
        })();
        call.outcome(&out);
        out
    }
    fn delete_prefix(&mut self, prefix: Vec<u8>) -> Result<u32, KError> {
        let mut call = HostCallGuard::start(&self.name, "kv.delete_prefix");
        let target = target_of(&prefix);
        let out = (|| {
            gate(&self.name, "kv.write", Some(&target))?;
            self.kv.delete_prefix(prefix).map_err(kv_error)
        })();
        call.outcome(&out);
        out
    }
    fn scan(&mut self, prefix: Vec<u8>, cursor: Option<Vec<u8>>, limit: u32) -> Result<Vec<wa::kernel::kv::Entry>, KError> {
        let mut call = HostCallGuard::start(&self.name, "kv.scan");
        let target = target_of(&prefix);
        let out = (|| {
            gate(&self.name, "kv.read", Some(&target))?;
            let rows = self.kv.scan(prefix, cursor, limit).map_err(kv_error)?;
            Ok(rows.into_iter().map(|(key, value)| wa::kernel::kv::Entry { key, value }).collect())
        })();
        call.outcome(&out);
        out
    }
}

impl wa::kernel::lifecycle::Host for State {
    fn stopping(&mut self) -> bool {
        let mut call = HostCallGuard::start(&self.name, "lifecycle.stopping");
        let stopping = self.shared.stop.load(Ordering::Relaxed);
        call.succeed();
        stopping
    }
    fn report(&mut self, state: wa::kernel::lifecycle::Health, detail: Option<String>) {
        let mut call = HostCallGuard::start(&self.name, "lifecycle.report");
        let text = match state {
            wa::kernel::lifecycle::Health::Starting => "starting",
            wa::kernel::lifecycle::Health::Ready => "ready",
            wa::kernel::lifecycle::Health::Degraded => "degraded",
        };
        *self.shared.health.lock().unwrap() = format!("{text}{}", detail.map(|d| format!(": {d}")).unwrap_or_default());
        call.succeed();
    }
}

impl wa::kernel::log::Host for State {
    /// Never policy-checked: a log line cannot exceed anything a person sees
    /// (`docs/GRANT-POLICY.md` step 4). Recorded for its latency like every other call.
    fn write(&mut self, level: wa::kernel::log::Level, target: String, message: String) {
        let mut call = HostCallGuard::start(&self.name, "log.write");
        if let Some(file) = self.log.as_mut() {
            let _ = writeln!(file, "{:?} {target}: {message}", level);
        }
        call.succeed();
    }
}

impl wa::kernel::credentials::Host for State {
    fn get(&mut self, name: String) -> Result<String, KError> {
        let mut call = HostCallGuard::start(&self.name, "credentials.get");
        let out = (|| {
            gate(&self.name, "credentials.read", Some(&name))?;
            self.secrets.get(&name).cloned().ok_or(KError::Refused(name.clone()))
        })();
        call.outcome(&out);
        out
    }
}

/// One run of `service.run(config)` until it returns, traps, or is stopped.
pub fn run_once(installed: &Installed, grant: &Grant, component: &Component, shared: &Arc<Shared>, log_file: std::fs::File) -> String {
    let engine = component.engine();
    let mut builder = WasiCtxBuilder::new();
    builder.args(&[installed.name.as_str()]);
    if let Ok(clone) = log_file.try_clone() {
        builder.stdout(wasmtime_wasi::cli::OutputFile::new(clone));
    }
    if let Ok(clone) = log_file.try_clone() {
        builder.stderr(wasmtime_wasi::cli::OutputFile::new(clone));
    }
    for (key, name) in &grant.env {
        if let Ok(value) = std::env::var(name) {
            builder.env(key, &value);
        }
    }
    // Secrets are read by the host from their file and handed only through `credentials.get`.
    let mut secrets = std::collections::BTreeMap::new();
    for (key, name) in &grant.file_env {
        let path = if name.starts_with('/') || name.as_bytes().get(1) == Some(&b':') { name.clone() } else { std::env::var(name).unwrap_or_default() };
        if let Ok(value) = std::fs::read_to_string(&path) {
            secrets.insert(key.clone(), value.trim().to_string());
        }
    }
    let memory_mb = installed.manifest.get("limits").and_then(|l| l.get("memory_mb")).and_then(serde_json::Value::as_u64).unwrap_or(512).clamp(16, 4096);
    let storage = installed.manifest.get("capabilities").and_then(|c| c.get("storage")).and_then(serde_json::Value::as_bool) == Some(true);
    let stt = installed.manifest.get("capabilities").and_then(|c| c.get("stt")).and_then(serde_json::Value::as_bool) == Some(true);
    if stt {
        service_stt::prewarm(); // keep the model warm from the start: no load on the first note
    }
    let state = State {
        wasi: builder.build(),
        table: ResourceTable::new(),
        limits: StoreLimitsBuilder::new().memory_size((memory_mb as usize) << 20).instances(64).build(),
        net: grant.net.clone(),
        shared: shared.clone(),
        kv: KvStore::new(storage.then(|| crate::components::component_dir().join(format!("{}.state", installed.name)).join("kv.sqlite"))),
        log: Some(log_file),
        secrets,
        stt,
        name: installed.name.clone(),
    };
    let mut store = Store::new(engine, state);
    store.limiter(|s| &mut s.limits);
    let stop_seen: Arc<Mutex<Option<Instant>>> = Arc::new(Mutex::new(None));
    let watcher = shared.clone();
    store.epoch_deadline_callback(move |_| {
        if watcher.stop.load(Ordering::Relaxed) {
            let mut seen = stop_seen.lock().unwrap();
            if seen.get_or_insert_with(Instant::now).elapsed() > Duration::from_secs(5) {
                return Err(wasmtime::Error::msg("service_stopped"));
            }
        }
        Ok(UpdateDeadline::Continue(10))
    });
    store.set_epoch_deadline(10);
    let mut linker: Linker<State> = Linker::new(engine);
    if let Err(error) = wasmtime_wasi::p2::add_to_linker_sync(&mut linker) {
        return format!("link_failed:{error}");
    }
    if let Err(error) = ServiceComponent::add_to_linker::<State, HasSelf<State>>(&mut linker, |s| s) {
        return format!("link_failed:{error}");
    }
    let bindings = match ServiceComponent::instantiate(&mut store, component, &linker) {
        Ok(bindings) => bindings,
        Err(error) => return format!("instantiate_failed:{error}"),
    };
    let config = grant.config.clone().unwrap_or_else(|| "{}".into());
    match bindings.wa_kernel_service().call_run(&mut store, &config) {
        Ok(Ok(())) => "exit_0".into(),
        Ok(Err(reason)) => format!("service_error:{reason}").chars().take(300).collect(),
        // `wasi:cli/exit` takes a `result`, not a code, so a component that exits non-zero reports
        // exit_1 (the wasip1 runner, with proc_exit, can report exit_3). Same shape either way, so
        // the supervisor's restart path reads one form.
        Err(error) => match error.downcast_ref::<wasmtime_wasi::I32Exit>() {
            Some(exit) => format!("exit_{}", exit.0),
            None if shared.stop.load(Ordering::Relaxed) => "stopped".into(),
            None => format!("trap:{}", error.root_cause()).chars().take(300).collect(),
        },
    }
}

/// Is this binary a component (vs. a core module)? The preamble's layer field says so.
pub fn is_component(bytes: &[u8]) -> bool {
    bytes.len() >= 8 && &bytes[0..4] == b"\0asm" && bytes[6..8] == [1, 0]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::services::{start, status, stop, support};

    /// End to end with the 0.1 component fixture (`svc-echo-v1`, wa:kernel@0.1): the poll contract
    /// still runs unchanged beside 0.2 — heartbeat, kv round trip, one granted http exchange, one
    /// refused, clean stop on `lifecycle.stopping()`, and crash mode (a non-zero exit, which
    /// `wasi:cli/exit` can only express as exit_1) for the restart path.
    #[test]
    fn fixture_v1_component_keeps_running_unchanged() {
        let _dir = crate::components::TEST_DIR_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        if support::install("v1", &["svc-echo-v1"]).is_none() {
            return;
        }
        let port = support::http_echo("pong");
        let config = serde_json::json!({
            "dial": format!("http://127.0.0.1:{port}/note"),
            "refused": "http://127.0.0.2:9/note",
        });
        let net = [format!("127.0.0.1:{port}")];
        let started = start(&serde_json::json!({"name": "svc-echo-v1", "net": net, "config": config}));
        assert_eq!(started["ok"], true, "{started}");
        let log = support::wait_for_log("svc-echo-v1", "dial ok", Duration::from_secs(15));
        assert!(log.contains("heartbeat start"), "{log}");
        assert!(log.contains("kv ok"), "the kv round trip ran: {log}");
        assert!(log.contains("dial ok status=200 bytes=4"), "the granted http exchange completed: {log}");
        assert!(log.contains("refused -13 (grant)"), "the ungranted address was refused: {log}");
        assert_eq!(status(Some("svc-echo-v1"))["state"], "running");
        let stopped = stop("svc-echo-v1");
        assert_eq!(stopped["was_running"], true);
        assert!(stopped["last_exit"].as_str().unwrap_or("").starts_with("exit_0"), "{stopped}");
        let log = crate::services::logs("svc-echo-v1", 16 << 10)["log"].as_str().unwrap_or("").to_string();
        assert!(log.contains("stopping cleanly"), "{log}");
        assert_eq!(start(&serde_json::json!({"name": "svc-echo-v1", "config": {"crash": true}}))["ok"], true);
        let deadline = Instant::now() + Duration::from_secs(10);
        let mut last = String::new();
        while Instant::now() < deadline {
            last = status(Some("svc-echo-v1"))["last_exit"].as_str().unwrap_or("").to_string();
            if last.starts_with("exit_1") {
                break;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        assert!(last.starts_with("exit_1"), "{last}");
        stop("svc-echo-v1");
    }

    use wa_grant_policy::Reason;

    /// The table in `docs/GRANT-POLICY.md` "Result mapping", as one test: a refusal the component
    /// can report, a short rate limit as `again` (the guest already retries that), and the exact
    /// reason word on the error so a component log says why.
    #[test]
    fn a_policy_answer_maps_to_the_guest_error() {
        assert!(gate_decision(Decision::Allow).is_ok());
        match gate_decision(Decision::Deny(Reason::NoPolicy)) {
            Err(KError::Refused(reason)) => assert_eq!(reason, "no_policy"),
            other => panic!("expected refused(no_policy), got {other:?}"),
        }
        match gate_decision(Decision::Deny(Reason::TargetNotAllowed)) {
            Err(KError::Refused(reason)) => assert_eq!(reason, "target_not_allowed"),
            other => panic!("expected refused(target_not_allowed), got {other:?}"),
        }
        match gate_decision(Decision::NeedsApproval(Reason::ApprovalRequired)) {
            Err(KError::Refused(reason)) => assert_eq!(reason, "approval_required"),
            other => panic!("expected refused(approval_required), got {other:?}"),
        }
        // Under a second the guest can just try again, so the host says `again`.
        assert!(matches!(
            gate_decision(Decision::RateLimited { retry_after_ms: 400, reason: Reason::TargetRateLimited }),
            Err(KError::Again)
        ));
        // Longer than that is a refusal with a number the component can log; retrying immediately
        // would only spend the budget.
        match gate_decision(Decision::RateLimited { retry_after_ms: 5_000, reason: Reason::CapabilityRateLimited }) {
            Err(KError::Refused(reason)) => assert_eq!(reason, "capability_rate_limited"),
            other => panic!("expected refused(capability_rate_limited), got {other:?}"),
        }
    }

    /// An address becomes a policy target in the form the rules are written in: lowercase, because
    /// host names are case-insensitive and the manifest grant already compares them that way, so an
    /// uppercase scheme/host in a URL cannot slip past a rule (or be refused by one).
    #[test]
    fn an_authority_is_a_policy_target_in_lowercase() {
        assert_eq!(authority_target("web.whatsapp.com:443"), "web.whatsapp.com:443");
        assert_eq!(authority_target("WEB.WhatsApp.COM:443"), "web.whatsapp.com:443");
        assert_eq!(authority_target("[::1]:8799"), "[::1]:8799");
        // The rule in the shipped default matches it whatever case the client used.
        let rule = wa_grant_policy::Pattern::new("web.whatsapp.com:443").unwrap();
        assert!(rule.matches(&authority_target("Web.WhatsApp.com:443")));
    }

    /// A kv key becomes a policy target with the same bytes the guest used: no truncation, so two
    /// keys that differ past a prefix do not share a budget.
    #[test]
    fn a_kv_key_is_a_target_without_being_rewritten() {
        assert_eq!(target_of(b"session/abc"), "session/abc");
        assert_eq!(target_of(&[0xff, 0xfe]), "\u{fffd}\u{fffd}");
    }
}
