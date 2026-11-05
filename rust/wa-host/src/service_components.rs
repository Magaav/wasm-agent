//! Service components on the `wa:kernel` WIT contract (docs/KERNEL.md): the `service-component`
//! world, run by the same supervisor as the wasip1 services (services.rs picks by binary header).
//! The guest imports websocket/http/kv/lifecycle/log/credentials and exports `service.run`.
use crate::components::{Grant, Installed};
use crate::service_io::{http_start, url_authority, HttpState, WsConn, AGAIN, CLOSED};
use crate::services::{dial_allowed, Shared};
use std::io::Write as _;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use wasmtime::component::{Component, HasSelf, Linker, Resource, ResourceTable};
use wasmtime::{Store, StoreLimits, StoreLimitsBuilder, UpdateDeadline};
use wasmtime_wasi::{WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};

// The native recognizer behind wa:kernel/speech (declared here, not in main.rs).
#[path = "service_stt.rs"]
mod service_stt;

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

pub struct WsSocket(Option<WsConn>);
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
    kv_path: Option<std::path::PathBuf>,
    kv: Option<rusqlite::Connection>,
    log: Option<std::fs::File>,
    secrets: std::collections::BTreeMap<String, String>,
    /// Manifest `capabilities.stt == true`.
    stt: bool,
}

impl WasiView for State {
    fn ctx(&mut self) -> WasiCtxView<'_> {
        WasiCtxView { ctx: &mut self.wasi, table: &mut self.table }
    }
}

impl State {
    fn db(&mut self) -> Result<&rusqlite::Connection, KError> {
        if self.kv.is_none() {
            let path = self.kv_path.clone().ok_or_else(|| KError::Refused("storage not declared".into()))?;
            let dir = path.parent().ok_or_else(|| KError::Failed("kv path".into()))?;
            std::fs::create_dir_all(dir).map_err(|e| KError::Failed(e.to_string()))?;
            let conn = rusqlite::Connection::open(&path).map_err(|e| KError::Failed(e.to_string()))?;
            conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; CREATE TABLE IF NOT EXISTS kv(k BLOB PRIMARY KEY, v BLOB NOT NULL);")
                .map_err(|e| KError::Failed(e.to_string()))?;
            self.kv = Some(conn);
        }
        Ok(self.kv.as_ref().expect("opened"))
    }
}

impl wa::kernel::types::Host for State {}

impl wa::kernel::websocket::Host for State {}
impl wa::kernel::websocket::HostSocket for State {
    fn connect(&mut self, url: String, origin: Option<String>) -> Result<Resource<WsSocket>, KError> {
        match url_authority(&url) {
            Some(addr) if dial_allowed(&self.net, &addr) => {}
            _ => return Err(KError::Refused(url)),
        }
        let conn = WsConn::open(&url, origin.as_deref()).map_err(KError::Failed)?;
        self.table.push(WsSocket(Some(conn))).map_err(|e| KError::Failed(e.to_string()))
    }
    fn send(&mut self, socket: Resource<WsSocket>, data: Vec<u8>) -> Result<(), KError> {
        match self.table.get(&socket).ok().and_then(|s| s.0.as_ref()) {
            Some(conn) if conn.send(data) == 0 => Ok(()),
            _ => Err(KError::Closed),
        }
    }
    fn recv(&mut self, socket: Resource<WsSocket>) -> Result<Vec<u8>, KError> {
        let Some(conn) = self.table.get_mut(&socket).ok().and_then(|s| s.0.as_mut()) else { return Err(KError::Closed) };
        match conn.next() {
            AGAIN => Err(KError::Again),
            CLOSED => Err(KError::Closed),
            _ => conn.take().ok_or(KError::Again),
        }
    }
    fn close(&mut self, socket: Resource<WsSocket>) {
        if let Ok(s) = self.table.get_mut(&socket) {
            s.0 = None;
        }
    }
    fn drop(&mut self, socket: Resource<WsSocket>) -> wasmtime::Result<()> {
        self.table.delete(socket)?;
        Ok(())
    }
}

impl wa::kernel::http::Host for State {}
impl wa::kernel::http::HostPending for State {
    fn start(&mut self, req: wa::kernel::http::Request) -> Result<Resource<HttpPending>, KError> {
        if !url_authority(&req.url).is_some_and(|a| dial_allowed(&self.net, &a)) {
            return Err(KError::Refused(req.url));
        }
        let headers: serde_json::Map<String, serde_json::Value> = req.headers.into_iter().map(|(k, v)| (k, serde_json::Value::String(v))).collect();
        let meta = serde_json::json!({"url": req.url, "method": req.method, "headers": headers});
        let state = http_start(&meta, req.body).map_err(KError::Failed)?;
        self.table.push(HttpPending(state)).map_err(|e| KError::Failed(e.to_string()))
    }
    fn poll(&mut self, pending: Resource<HttpPending>) -> Result<wa::kernel::http::Response, KError> {
        let Ok(p) = self.table.get_mut(&pending) else { return Err(KError::Closed) };
        match p.0.poll() {
            AGAIN => Err(KError::Again),
            status if status >= 0 => match &p.0 {
                HttpState::Done(_, body) => Ok(wa::kernel::http::Response { status: status as u16, body: body.clone() }),
                _ => Err(KError::Failed("no body".into())),
            },
            _ => Err(KError::Failed("exchange failed".into())),
        }
    }
    fn drop(&mut self, pending: Resource<HttpPending>) -> wasmtime::Result<()> {
        self.table.delete(pending)?;
        Ok(())
    }
}

impl wa::kernel::speech::Host for State {}
impl wa::kernel::speech::HostJob for State {
    fn start(&mut self, audio: Vec<u8>, mime: String, language: String) -> Result<Resource<SpeechJob>, KError> {
        if !self.stt {
            return Err(KError::Refused("stt not declared".into()));
        }
        let slot = service_stt::submit(audio, &mime, &language).map_err(KError::Failed)?;
        self.table.push(SpeechJob { slot, language }).map_err(|e| KError::Failed(e.to_string()))
    }
    fn poll(&mut self, job: Resource<SpeechJob>) -> Result<wa::kernel::speech::Transcript, KError> {
        let Ok(job) = self.table.get(&job) else { return Err(KError::Closed) };
        match job.slot.lock().unwrap().clone() {
            service_stt::JobState::Queued => Err(KError::Again),
            service_stt::JobState::Done { text, elapsed_ms } => Ok(wa::kernel::speech::Transcript { text, language: job.language.clone(), elapsed_ms }),
            service_stt::JobState::Failed(reason) => Err(KError::Failed(reason)),
        }
    }
    fn drop(&mut self, job: Resource<SpeechJob>) -> wasmtime::Result<()> {
        self.table.delete(job)?;
        Ok(())
    }
}

impl wa::kernel::kv::Host for State {
    fn get(&mut self, key: Vec<u8>) -> Result<Option<Vec<u8>>, KError> {
        let db = self.db()?;
        match db.query_row("SELECT v FROM kv WHERE k=?1", rusqlite::params![key], |r| r.get(0)) {
            Ok(v) => Ok(Some(v)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(KError::Failed(e.to_string())),
        }
    }
    fn set(&mut self, key: Vec<u8>, value: Vec<u8>) -> Result<(), KError> {
        self.db()?
            .execute("INSERT INTO kv(k,v) VALUES(?1,?2) ON CONFLICT(k) DO UPDATE SET v=excluded.v", rusqlite::params![key, value])
            .map(|_| ())
            .map_err(|e| KError::Failed(e.to_string()))
    }
    fn delete(&mut self, key: Vec<u8>) -> Result<(), KError> {
        self.db()?.execute("DELETE FROM kv WHERE k=?1", rusqlite::params![key]).map(|_| ()).map_err(|e| KError::Failed(e.to_string()))
    }
    fn delete_prefix(&mut self, prefix: Vec<u8>) -> Result<u32, KError> {
        let db = self.db()?;
        let n = if prefix.is_empty() {
            db.execute("DELETE FROM kv", [])
        } else {
            db.execute("DELETE FROM kv WHERE substr(k,1,?2)=?1", rusqlite::params![prefix, prefix.len() as i64])
        };
        n.map(|n| n as u32).map_err(|e| KError::Failed(e.to_string()))
    }
    fn scan(&mut self, prefix: Vec<u8>, cursor: Option<Vec<u8>>, limit: u32) -> Result<Vec<wa::kernel::kv::Entry>, KError> {
        let db = self.db()?;
        let limit = limit.clamp(1, 10_000) as i64;
        let after = cursor.unwrap_or_default();
        // Empty prefix = every key; ordering by key with an exclusive cursor gives stable pages.
        let mut stmt = db
            .prepare("SELECT k,v FROM kv WHERE (?2 = 0 OR substr(k,1,?2)=?1) AND (?4 = 0 OR k > ?3) ORDER BY k LIMIT ?5")
            .map_err(|e| KError::Failed(e.to_string()))?;
        let rows = stmt
            .query_map(rusqlite::params![prefix, prefix.len() as i64, after, after.len() as i64, limit], |r| {
                Ok(wa::kernel::kv::Entry { key: r.get(0)?, value: r.get(1)? })
            })
            .map_err(|e| KError::Failed(e.to_string()))?;
        rows.collect::<Result<Vec<_>, _>>().map_err(|e| KError::Failed(e.to_string()))
    }
}

impl wa::kernel::lifecycle::Host for State {
    fn stopping(&mut self) -> bool {
        self.shared.stop.load(Ordering::Relaxed)
    }
    fn report(&mut self, state: wa::kernel::lifecycle::Health, detail: Option<String>) {
        let text = match state {
            wa::kernel::lifecycle::Health::Starting => "starting",
            wa::kernel::lifecycle::Health::Ready => "ready",
            wa::kernel::lifecycle::Health::Degraded => "degraded",
        };
        *self.shared.health.lock().unwrap() = format!("{text}{}", detail.map(|d| format!(": {d}")).unwrap_or_default());
    }
}

impl wa::kernel::log::Host for State {
    fn write(&mut self, level: wa::kernel::log::Level, target: String, message: String) {
        if let Some(file) = self.log.as_mut() {
            let _ = writeln!(file, "{:?} {target}: {message}", level);
        }
    }
}

impl wa::kernel::credentials::Host for State {
    fn get(&mut self, name: String) -> Result<String, KError> {
        self.secrets.get(&name).cloned().ok_or(KError::Refused(name))
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
    let state = State {
        wasi: builder.build(),
        table: ResourceTable::new(),
        limits: StoreLimitsBuilder::new().memory_size((memory_mb as usize) << 20).instances(64).build(),
        net: grant.net.clone(),
        shared: shared.clone(),
        kv_path: storage.then(|| crate::components::component_dir().join(format!("{}.state", installed.name)).join("kv.sqlite")),
        kv: None,
        log: Some(log_file),
        secrets,
        stt,
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
        Err(_) if shared.stop.load(Ordering::Relaxed) => "stopped".into(),
        Err(error) => format!("trap:{}", error.root_cause()).chars().take(300).collect(),
    }
}

/// Is this binary a component (vs. a core module)? The preamble's layer field says so.
pub fn is_component(bytes: &[u8]) -> bool {
    bytes.len() >= 8 && &bytes[0..4] == b"\0asm" && bytes[6..8] == [1, 0]
}
