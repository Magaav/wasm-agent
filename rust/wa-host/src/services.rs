//! Service components: long-lived, supervised wasip1 modules (docs/SERVICE-COMPONENTS.md).
//!
//! A service is an installed component (same files, pin and manifest as `components.rs`, with
//! `"kind": "service"`) compiled for `wasm32-wasip1` - what Go's `GOOS=wasip1` produces. The host
//! runs `_start` on its own thread, restarts it with backoff when it exits or traps, and stops it on
//! request. Nothing is ambient: no filesystem, no inherited environment, no sockets of its own.
//!
//! Host imports (all non-blocking - a blocking call would freeze the guest's scheduler):
//!
//!   wa_sock.connect(addr_ptr, addr_len) -> handle | -13 refused | -1 failed
//!   wa_sock.read(handle, ptr, len)      -> bytes | 0 EOF | -11 again | -1 failed
//!   wa_sock.write(handle, ptr, len)     -> bytes | -11 again | -1 failed
//!   wa_sock.close(handle)               -> 0
//!   wa_ctl.stopping()                   -> 1 once a stop was requested (exit cleanly), else 0
//!
//! `connect` takes "host:port" and is allowed only for a granted address: an exact entry, or a
//! `*.suffix:port` entry for any host under that suffix. stdout/stderr go to a bounded log file
//! beside the component (`<name>.service.log`, rotated once at 8 MiB on each start).
use crate::components::{load, Grant, Installed};
use anyhow::{anyhow, Result};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::{ErrorKind, Read, Write};
use std::net::TcpStream;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use wasmtime::{Caller, Linker, Module, Store, StoreLimits, StoreLimitsBuilder, UpdateDeadline};
use wasmtime_wasi::p1::{self, WasiP1Ctx};
use wasmtime_wasi::WasiCtxBuilder;

const EAGAIN: i32 = -11;
const REFUSED: i32 = -13;
const MAX_SOCKETS: usize = 64;
const MAX_IO: usize = 256 << 10;
const STOP_GRACE: Duration = Duration::from_secs(5);
const BACKOFF_MAX: Duration = Duration::from_secs(60);
const HEALTHY: Duration = Duration::from_secs(600);
const DEFAULT_MEMORY_MB: u64 = 512;

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

/// Does `addr` ("host:port") match a granted entry: exact, or "*.suffix:port"?
pub fn dial_allowed(granted: &[String], addr: &str) -> bool {
    let Some((host, port)) = addr.rsplit_once(':') else { return false };
    if host.is_empty() || port.parse::<u16>().is_err() || host.contains(['/', '@', ' ']) {
        return false;
    }
    let host = host.to_ascii_lowercase();
    granted.iter().any(|entry| {
        let entry = entry.to_ascii_lowercase();
        if entry == format!("{host}:{port}") {
            return true;
        }
        match entry.strip_prefix("*.").and_then(|rest| rest.rsplit_once(':')) {
            Some((suffix, p)) => p == port && host.ends_with(&format!(".{suffix}")) && host.len() > suffix.len() + 1,
            None => false,
        }
    })
}

#[derive(Default)]
pub(crate) struct Shared {
    pub(crate) stop: AtomicBool,
    /// Last `lifecycle.report` from a component service ("" for wasip1 modules).
    pub(crate) health: Mutex<String>,
    restarts: AtomicU64,
    sockets: AtomicU64,
    state: Mutex<String>,
    last_exit: Mutex<String>,
    started_at: AtomicU64,
}

struct Handle {
    shared: Arc<Shared>,
    sha256: String,
    thread: Option<std::thread::JoinHandle<()>>,
}

fn registry() -> &'static Mutex<HashMap<String, Handle>> {
    static REGISTRY: OnceLock<Mutex<HashMap<String, Handle>>> = OnceLock::new();
    REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}

struct State {
    wasi: WasiP1Ctx,
    socks: Vec<Option<TcpStream>>,
    ws: Vec<Option<crate::service_io::WsConn>>,
    http: HashMap<i32, crate::service_io::HttpState>,
    next_http: i32,
    /// `wa_kv`: the component's own key-value file (manifest `capabilities.storage: true`), opened lazily.
    kv_path: Option<std::path::PathBuf>,
    kv: Option<rusqlite::Connection>,
    kv_buf: Vec<u8>,
    net: Vec<String>,
    shared: Arc<Shared>,
    limits: StoreLimits,
}

fn memory(caller: &mut Caller<'_, State>) -> Option<wasmtime::Memory> {
    caller.get_export("memory").and_then(|e| e.into_memory())
}

fn linker(engine: &wasmtime::Engine) -> Result<Linker<State>> {
    let mut linker: Linker<State> = Linker::new(engine);
    p1::add_to_linker_sync(&mut linker, |s: &mut State| &mut s.wasi)?;
    linker.func_wrap("wa_sock", "connect", |mut c: Caller<'_, State>, ptr: i32, len: i32| -> i32 {
        if !(1..=255).contains(&len) {
            return REFUSED;
        }
        let Some(mem) = memory(&mut c) else { return -1 };
        let mut buf = vec![0u8; len as usize];
        if mem.read(&c, ptr as usize, &mut buf).is_err() {
            return -1;
        }
        let addr = String::from_utf8_lossy(&buf).into_owned();
        if !dial_allowed(&c.data().net, &addr) {
            return REFUSED;
        }
        if c.data().socks.iter().filter(|s| s.is_some()).count() >= MAX_SOCKETS {
            return -1;
        }
        // The connect itself blocks briefly (DNS + TCP handshake, bounded); every read/write after
        // it is non-blocking.
        let stream = match std::net::ToSocketAddrs::to_socket_addrs(&addr.as_str())
            .ok()
            .and_then(|mut addrs| addrs.find_map(|a| TcpStream::connect_timeout(&a, Duration::from_secs(10)).ok()))
        {
            Some(stream) => stream,
            None => return -1,
        };
        stream.set_nonblocking(true).ok();
        stream.set_nodelay(true).ok();
        let state = c.data_mut();
        state.shared.sockets.fetch_add(1, Ordering::Relaxed);
        if let Some(slot) = state.socks.iter().position(Option::is_none) {
            state.socks[slot] = Some(stream);
            slot as i32
        } else {
            state.socks.push(Some(stream));
            (state.socks.len() - 1) as i32
        }
    })?;
    linker.func_wrap("wa_sock", "read", |mut c: Caller<'_, State>, h: i32, ptr: i32, n: i32| -> i32 {
        let n = (n.max(0) as usize).min(MAX_IO);
        let mut buf = vec![0u8; n];
        let result = match c.data_mut().socks.get_mut(h as usize).and_then(Option::as_mut) {
            Some(stream) => stream.read(&mut buf),
            None => return -1,
        };
        match result {
            Ok(k) => {
                let Some(mem) = memory(&mut c) else { return -1 };
                if mem.write(&mut c, ptr as usize, &buf[..k]).is_err() {
                    return -1;
                }
                k as i32
            }
            Err(e) if e.kind() == ErrorKind::WouldBlock => EAGAIN,
            Err(_) => -1,
        }
    })?;
    linker.func_wrap("wa_sock", "write", |mut c: Caller<'_, State>, h: i32, ptr: i32, n: i32| -> i32 {
        let n = (n.max(0) as usize).min(MAX_IO);
        let Some(mem) = memory(&mut c) else { return -1 };
        let mut buf = vec![0u8; n];
        if mem.read(&c, ptr as usize, &mut buf).is_err() {
            return -1;
        }
        match c.data_mut().socks.get_mut(h as usize).and_then(Option::as_mut) {
            Some(stream) => match stream.write(&buf) {
                Ok(k) => k as i32,
                Err(e) if e.kind() == ErrorKind::WouldBlock => EAGAIN,
                Err(_) => -1,
            },
            None => -1,
        }
    })?;
    linker.func_wrap("wa_sock", "close", |mut c: Caller<'_, State>, h: i32| -> i32 {
        let state = c.data_mut();
        if let Some(slot) = state.socks.get_mut(h as usize) {
            if slot.take().is_some() {
                state.shared.sockets.fetch_sub(1, Ordering::Relaxed);
            }
        }
        0
    })?;
    // Host websocket + HTTP (service_io.rs): TLS in the host, frames and bodies across the boundary.
    fn read_bytes(c: &mut Caller<'_, State>, ptr: i32, len: i32, max: usize) -> Option<Vec<u8>> {
        if len < 0 || len as usize > max {
            return None;
        }
        let mem = memory(c)?;
        let mut buf = vec![0u8; len as usize];
        mem.read(&*c, ptr as usize, &mut buf).ok()?;
        Some(buf)
    }
    fn write_bytes(c: &mut Caller<'_, State>, ptr: i32, data: &[u8]) -> bool {
        memory(c).is_some_and(|mem| mem.write(&mut *c, ptr as usize, data).is_ok())
    }
    linker.func_wrap("wa_ws", "connect", |mut c: Caller<'_, State>, up: i32, ul: i32, op: i32, ol: i32| -> i32 {
        let Some(url) = read_bytes(&mut c, up, ul, 2048).and_then(|b| String::from_utf8(b).ok()) else { return -1 };
        let origin = if ol > 0 { read_bytes(&mut c, op, ol, 512).and_then(|b| String::from_utf8(b).ok()) } else { None };
        match crate::service_io::url_authority(&url) {
            Some(addr) if dial_allowed(&c.data().net, &addr) => {}
            _ => return crate::service_io::REFUSED,
        }
        if c.data().ws.iter().filter(|w| w.is_some()).count() >= 8 {
            return -1;
        }
        match crate::service_io::WsConn::open(&url, origin.as_deref()) {
            Ok(conn) => {
                let state = c.data_mut();
                if let Some(slot) = state.ws.iter().position(Option::is_none) {
                    state.ws[slot] = Some(conn);
                    slot as i32
                } else {
                    state.ws.push(Some(conn));
                    (state.ws.len() - 1) as i32
                }
            }
            Err(error) => {
                eprintln!("[service] wa_ws connect {url}: {error}");
                -1
            }
        }
    })?;
    linker.func_wrap("wa_ws", "next", |mut c: Caller<'_, State>, h: i32| -> i32 {
        match c.data_mut().ws.get_mut(h as usize).and_then(Option::as_mut) {
            Some(conn) => conn.next(),
            None => crate::service_io::CLOSED,
        }
    })?;
    linker.func_wrap("wa_ws", "take", |mut c: Caller<'_, State>, h: i32, ptr: i32, len: i32| -> i32 {
        let data = match c.data_mut().ws.get_mut(h as usize).and_then(Option::as_mut) {
            Some(conn) => match conn.take() {
                Some(data) if data.len() <= len.max(0) as usize => data,
                Some(_) => return -1,
                None => return crate::service_io::AGAIN,
            },
            None => return crate::service_io::CLOSED,
        };
        if write_bytes(&mut c, ptr, &data) { data.len() as i32 } else { -1 }
    })?;
    linker.func_wrap("wa_ws", "send", |mut c: Caller<'_, State>, h: i32, ptr: i32, len: i32| -> i32 {
        let Some(data) = read_bytes(&mut c, ptr, len, 32 << 20) else { return -1 };
        match c.data().ws.get(h as usize).and_then(Option::as_ref) {
            Some(conn) => conn.send(data),
            None => crate::service_io::CLOSED,
        }
    })?;
    linker.func_wrap("wa_ws", "close", |mut c: Caller<'_, State>, h: i32| -> i32 {
        if let Some(slot) = c.data_mut().ws.get_mut(h as usize) {
            *slot = None;
        }
        0
    })?;
    linker.func_wrap("wa_http", "start", |mut c: Caller<'_, State>, mp: i32, ml: i32, bp: i32, bl: i32| -> i32 {
        let Some(meta) = read_bytes(&mut c, mp, ml, 64 << 10).and_then(|b| serde_json::from_slice::<Value>(&b).ok()) else { return -1 };
        let Some(body) = read_bytes(&mut c, bp, bl, 96 << 20) else { return -1 };
        let allowed = meta.get("url").and_then(Value::as_str).and_then(crate::service_io::url_authority).is_some_and(|a| dial_allowed(&c.data().net, &a));
        if !allowed {
            return crate::service_io::REFUSED;
        }
        if c.data().http.len() >= 32 {
            return -1;
        }
        match crate::service_io::http_start(&meta, body) {
            Ok(state) => {
                let s = c.data_mut();
                let id = s.next_http;
                s.next_http = s.next_http.wrapping_add(1).max(1);
                s.http.insert(id, state);
                id
            }
            Err(_) => -1,
        }
    })?;
    linker.func_wrap("wa_http", "poll", |mut c: Caller<'_, State>, id: i32| -> i32 {
        c.data_mut().http.get_mut(&id).map(|s| s.poll()).unwrap_or(-1)
    })?;
    linker.func_wrap("wa_http", "body_len", |c: Caller<'_, State>, id: i32| -> i32 {
        match c.data().http.get(&id) {
            Some(crate::service_io::HttpState::Done(_, body)) => body.len() as i32,
            _ => -1,
        }
    })?;
    linker.func_wrap("wa_http", "body", |mut c: Caller<'_, State>, id: i32, ptr: i32, len: i32| -> i32 {
        let body = match c.data().http.get(&id) {
            Some(crate::service_io::HttpState::Done(_, body)) if body.len() <= len.max(0) as usize => body.clone(),
            _ => return -1,
        };
        if write_bytes(&mut c, ptr, &body) { body.len() as i32 } else { -1 }
    })?;
    linker.func_wrap("wa_http", "free", |mut c: Caller<'_, State>, id: i32| -> i32 {
        c.data_mut().http.remove(&id);
        0
    })?;
    // wa_kv: a durable key-value store private to this component (one SQLite file in
    // <components>/<name>.state/). Values up to 16 MiB; `get`/`dump` stage bytes for `take`.
    fn kv<'a>(c: &'a mut Caller<'_, State>) -> Option<&'a rusqlite::Connection> {
        if c.data().kv.is_none() {
            let path = c.data().kv_path.clone()?;
            std::fs::create_dir_all(path.parent()?).ok()?;
            let conn = rusqlite::Connection::open(&path).ok()?;
            conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; CREATE TABLE IF NOT EXISTS kv(k BLOB PRIMARY KEY, v BLOB NOT NULL);").ok()?;
            c.data_mut().kv = Some(conn);
        }
        c.data().kv.as_ref()
    }
    linker.func_wrap("wa_kv", "put", |mut c: Caller<'_, State>, kp: i32, kl: i32, vp: i32, vl: i32| -> i32 {
        let (Some(k), Some(v)) = (read_bytes(&mut c, kp, kl, 4096), read_bytes(&mut c, vp, vl, 16 << 20)) else { return -1 };
        match kv(&mut c) {
            Some(db) => db.execute("INSERT INTO kv(k,v) VALUES(?1,?2) ON CONFLICT(k) DO UPDATE SET v=excluded.v", rusqlite::params![k, v]).map(|_| 0).unwrap_or(-1),
            None => crate::service_io::REFUSED,
        }
    })?;
    linker.func_wrap("wa_kv", "del", |mut c: Caller<'_, State>, kp: i32, kl: i32| -> i32 {
        let Some(k) = read_bytes(&mut c, kp, kl, 4096) else { return -1 };
        match kv(&mut c) {
            Some(db) => db.execute("DELETE FROM kv WHERE k=?1", rusqlite::params![k]).map(|n| n as i32).unwrap_or(-1),
            None => crate::service_io::REFUSED,
        }
    })?;
    linker.func_wrap("wa_kv", "del_prefix", |mut c: Caller<'_, State>, pp: i32, pl: i32| -> i32 {
        let Some(p) = read_bytes(&mut c, pp, pl, 4096) else { return -1 };
        match kv(&mut c) {
            Some(db) => db.execute("DELETE FROM kv WHERE substr(k,1,?2)=?1", rusqlite::params![p, p.len() as i64]).map(|n| n as i32).unwrap_or(-1),
            None => crate::service_io::REFUSED,
        }
    })?;
    linker.func_wrap("wa_kv", "get", |mut c: Caller<'_, State>, kp: i32, kl: i32| -> i32 {
        let Some(k) = read_bytes(&mut c, kp, kl, 4096) else { return -1 };
        let value: Option<Vec<u8>> = match kv(&mut c) {
            Some(db) => db.query_row("SELECT v FROM kv WHERE k=?1", rusqlite::params![k], |r| r.get(0)).ok(),
            None => return crate::service_io::REFUSED,
        };
        match value {
            Some(v) => {
                let n = v.len() as i32;
                c.data_mut().kv_buf = v;
                n
            }
            None => -2,
        }
    })?;
    // dump(prefix) -> total bytes of [u32 klen][k][u32 vlen][v]... (little endian), staged for take.
    linker.func_wrap("wa_kv", "dump", |mut c: Caller<'_, State>, pp: i32, pl: i32| -> i32 {
        let Some(p) = read_bytes(&mut c, pp, pl, 4096) else { return -1 };
        let mut out = Vec::new();
        {
            let Some(db) = kv(&mut c) else { return crate::service_io::REFUSED };
            // The empty prefix is a plain full scan (no comparison against an empty blob).
            let sql = if p.is_empty() { "SELECT k,v FROM kv WHERE ?2 = 0 OR ?1 IS NULL ORDER BY k" } else { "SELECT k,v FROM kv WHERE substr(k,1,?2)=?1 ORDER BY k" };
            let mut stmt = match db.prepare(sql) {
                Ok(stmt) => stmt,
                Err(error) => {
                    eprintln!("[service] wa_kv dump prepare: {error}");
                    return -1;
                }
            };
            let rows = match stmt.query_map(rusqlite::params![p, p.len() as i64], |r| Ok((r.get::<_, Vec<u8>>(0)?, r.get::<_, Vec<u8>>(1)?))) {
                Ok(rows) => rows,
                Err(error) => {
                    eprintln!("[service] wa_kv dump query: {error}");
                    return -1;
                }
            };
            let (mut count, mut failed) = (0usize, 0usize);
            for row in rows {
                let (k, v) = match row {
                    Ok(row) => row,
                    Err(error) => {
                        if failed == 0 {
                            eprintln!("[service] wa_kv dump row: {error}");
                        }
                        failed += 1;
                        continue;
                    }
                };
                count += 1;
                out.extend((k.len() as u32).to_le_bytes());
                out.extend(&k);
                out.extend((v.len() as u32).to_le_bytes());
                out.extend(&v);
                if out.len() > (512 << 20) {
                    return -1;
                }
            }
            eprintln!("[service] wa_kv dump: {count} rows, {failed} unreadable, {} bytes", out.len());
        }
        let n = out.len() as i32;
        c.data_mut().kv_buf = out;
        n
    })?;
    linker.func_wrap("wa_kv", "take", |mut c: Caller<'_, State>, ptr: i32, len: i32| -> i32 {
        let buf = std::mem::take(&mut c.data_mut().kv_buf);
        if buf.len() > len.max(0) as usize {
            return -1;
        }
        if write_bytes(&mut c, ptr, &buf) { buf.len() as i32 } else { -1 }
    })?;
    linker.func_wrap("wa_ctl", "stopping", |c: Caller<'_, State>| -> i32 { c.data().shared.stop.load(Ordering::Relaxed) as i32 })?;
    Ok(linker)
}

fn log_path(name: &str) -> std::path::PathBuf {
    crate::components::component_dir().join(format!("{name}.service.log"))
}

fn open_log(name: &str) -> Result<std::fs::File> {
    // Bounded store (store.rs): a service log has a per-component quota, applied at start - the one
    // moment the host owns the file. While the service runs the guest holds the handle, so the
    // sweep alerts at 80 % instead of rotating a file out from under it.
    crate::store::enforce_service_log(&crate::components::component_dir(), name, crate::store::service_log_quota());
    let path = log_path(name);
    Ok(std::fs::OpenOptions::new().create(true).append(true).open(path)?)
}

/// One run of `_start` until it returns, traps, or is stopped.
fn run_once(installed: &Installed, grant: &Grant, module: &Module, shared: &Arc<Shared>) -> String {
    let engine = module.engine();
    let mut builder = WasiCtxBuilder::new();
    builder.args(&[installed.name.as_str()]);
    match open_log(&installed.name) {
        Ok(file) => {
            let err = file.try_clone().ok();
            builder.stdout(wasmtime_wasi::cli::OutputFile::new(file));
            if let Some(err) = err {
                builder.stderr(wasmtime_wasi::cli::OutputFile::new(err));
            }
        }
        Err(error) => return format!("log_unavailable:{error}"),
    }
    for (key, name) in &grant.env {
        if let Ok(value) = std::env::var(name) {
            builder.env(key, &value);
        }
    }
    if let Some(config) = &grant.config {
        builder.env("WA_COMPONENT_CONFIG", config);
    }
    for (key, name) in &grant.file_env {
        let path = if name.starts_with('/') || name.as_bytes().get(1) == Some(&b':') { name.clone() } else { std::env::var(name).unwrap_or_default() };
        match std::fs::read_to_string(&path) {
            Ok(value) => {
                builder.env(key, value.trim());
            }
            Err(_) => return format!("file_env_unreadable:{key}"),
        }
    }
    let memory_mb = installed.manifest.get("limits").and_then(|l| l.get("memory_mb")).and_then(Value::as_u64).unwrap_or(DEFAULT_MEMORY_MB).clamp(16, 4096);
    let limits = StoreLimitsBuilder::new().memory_size((memory_mb as usize) << 20).instances(16).build();
    let storage = installed.manifest.get("capabilities").and_then(|c| c.get("storage")).and_then(Value::as_bool) == Some(true);
    let kv_path = storage.then(|| crate::components::component_dir().join(format!("{}.state", installed.name)).join("kv.sqlite"));
    let state = State { wasi: builder.build_p1(), socks: Vec::new(), ws: Vec::new(), http: HashMap::new(), next_http: 1, kv_path, kv: None, kv_buf: Vec::new(), net: grant.net.clone(), shared: shared.clone(), limits };
    let mut store = Store::new(engine, state);
    store.limiter(|s| &mut s.limits);
    // Never preempted while running; after a stop request it gets STOP_GRACE to exit on its own
    // (wa_ctl.stopping), then the epoch traps it.
    let stop_seen: Arc<Mutex<Option<Instant>>> = Arc::new(Mutex::new(None));
    let watcher = shared.clone();
    store.epoch_deadline_callback(move |_| {
        if watcher.stop.load(Ordering::Relaxed) {
            let mut seen = stop_seen.lock().unwrap();
            let since = *seen.get_or_insert_with(Instant::now);
            if since.elapsed() > STOP_GRACE {
                return Err(wasmtime::Error::msg("service_stopped"));
            }
        }
        Ok(UpdateDeadline::Continue(10))
    });
    store.set_epoch_deadline(10);
    let linker = match linker(engine) {
        Ok(linker) => linker,
        Err(error) => return format!("link_failed:{error}"),
    };
    let instance = match linker.instantiate(&mut store, module) {
        Ok(instance) => instance,
        Err(error) => return format!("instantiate_failed:{error}"),
    };
    let start = match instance.get_typed_func::<(), ()>(&mut store, "_start") {
        Ok(start) => start,
        Err(_) => return "no_start_export".into(),
    };
    let outcome = match start.call(&mut store, ()) {
        Ok(()) => "exit_0".to_string(),
        Err(error) => match error.downcast_ref::<wasmtime_wasi::I32Exit>() {
            Some(exit) => format!("exit_{}", exit.0),
            None if shared.stop.load(Ordering::Relaxed) => "stopped".to_string(),
            None => format!("trap:{}", error.root_cause()).chars().take(300).collect(),
        },
    };
    let open = store.data().socks.iter().filter(|s| s.is_some()).count() as u64;
    shared.sockets.fetch_sub(open.min(shared.sockets.load(Ordering::Relaxed)), Ordering::Relaxed);
    outcome
}

fn set(shared: &Shared, state: &str) {
    *shared.state.lock().unwrap() = state.to_string();
}

/// Start a service (idempotent: a running one with the same pin is left alone).
pub fn start(request: &Value) -> Value {
    let name = request.get("name").and_then(Value::as_str).unwrap_or_default().to_string();
    let installed = match load(&name) {
        Ok(installed) => installed,
        Err(error) => return json!({"ok": false, "error": error.to_string()}),
    };
    if installed.manifest.get("kind").and_then(Value::as_str) != Some("service") {
        return json!({"ok": false, "error": "component_is_not_a_service"});
    }
    let grant = match Grant::from_request(request).and_then(|g| g.check(&installed.manifest).map(|_| g)) {
        Ok(grant) => grant,
        Err(error) => return json!({"ok": false, "error": error.to_string()}),
    };
    let mut services = registry().lock().unwrap();
    if let Some(existing) = services.get(&name) {
        let running = existing.thread.as_ref().is_some_and(|t| !t.is_finished());
        if running && existing.sha256 == installed.sha256 {
            return json!({"ok": true, "name": name, "already_running": true, "sha256": installed.sha256});
        }
        if running {
            return json!({"ok": false, "error": "service_running_with_another_pin: stop it first"});
        }
    }
    // The transactional install (docs/STATE.md): before anything is compiled or started, a
    // manifest that declares `state_version` must find its namespace at that version. The migration
    // runs on a snapshot copy and is swapped in only if it succeeds; a refusal here leaves the
    // previous instance and its state exactly as they were, and nothing has started.
    let state = match crate::state_host::prepare_install(&installed) {
        Ok(outcome) => outcome,
        Err(error) => return json!({"ok": false, "name": name, "error": error}),
    };
    // The two component-facing providers' grants, read from the same (already checked) manifest:
    // `bus` patterns and `queue` interfaces/namespaces. A malformed grant is a refusal here, before
    // anything runs; a component that declares neither gets no bus grant and no queue interface, so
    // every call it makes on them is refused by the ACL/gate rather than silently allowed.
    let bus_grants = match crate::bus_host::register(&name, &installed.manifest) {
        Ok(grants) => grants,
        Err(error) => return json!({"ok": false, "name": name, "error": error}),
    };
    let queue_grants = match crate::queue_host::node().register(&name, &installed.manifest) {
        Ok(grants) => grants,
        Err(error) => return json!({"ok": false, "name": name, "error": error}),
    };
    let engine = match crate::components::engine() {
        Ok(engine) => engine,
        Err(error) => return json!({"ok": false, "error": error.to_string()}),
    };
    // A component on the wa:kernel contract runs through service_components; a core module
    // through the wasip1 runner below. The binary's preamble says which, and for a component its
    // own imports say which version of the contract it speaks: `wa:kernel/*@0.2.0` is the native
    // async runner (and the async-capable engine it needs), everything else is 0.1, unchanged.
    enum Compiled {
        Module(Module),
        Component(wasmtime::component::Component),
        ComponentV2(wasmtime::component::Component),
    }
    let compiled = if crate::service_components::is_component(&installed.bytes) {
        // The contract a component speaks is in its own imports, and a 0.2 component only compiles
        // on an engine with the async feature: the async engine is therefore the one that reads the
        // answer, and a 0.1 component is then compiled again on the engine every other component
        // uses, so nothing about 0.1 behaviour changes.
        let async_engine = match crate::service_components_v2::engine() {
            Ok(engine) => engine,
            Err(error) => return json!({"ok": false, "error": format!("engine_failed:{error}")}),
        };
        let probe = match wasmtime::component::Component::new(&async_engine, &installed.bytes) {
            Ok(component) => component,
            Err(error) => return json!({"ok": false, "error": format!("compile_failed:{error}")}),
        };
        match crate::service_components_v2::Contract::of(&probe) {
            crate::service_components_v2::Contract::V2 => Compiled::ComponentV2(probe),
            crate::service_components_v2::Contract::V1 => match wasmtime::component::Component::new(&engine, &installed.bytes) {
                Ok(c) => Compiled::Component(c),
                Err(error) => return json!({"ok": false, "error": format!("compile_failed:{error}")}),
            },
        }
    } else {
        match Module::new(&engine, &installed.bytes) {
            Ok(m) => Compiled::Module(m),
            Err(error) => return json!({"ok": false, "error": format!("compile_failed:{error}")}),
        }
    };
    let shared = Arc::new(Shared::default());
    set(&shared, "starting");
    let thread_shared = shared.clone();
    let sha256 = installed.sha256.clone();
    let thread = std::thread::Builder::new().name(format!("wa-service-{name}")).spawn(move || {
        let mut backoff = Duration::from_secs(1);
        loop {
            set(&thread_shared, "running");
            // Health is a gauge, not a log line: 1 while a run is in flight, 0 when the supervisor
            // stops for good (docs/TELEMETRY.md).
            crate::node_telemetry::record_service_health(&installed.name, true);
            thread_shared.started_at.store(now(), Ordering::Relaxed);
            let run_start_ms = crate::node_telemetry::now_ms();
            let began = Instant::now();
            let outcome = match &compiled {
                Compiled::Module(module) => run_once(&installed, &grant, module, &thread_shared),
                Compiled::Component(component) => match open_log(&installed.name) {
                    Ok(log) => crate::service_components::run_once(&installed, &grant, component, &thread_shared, log),
                    Err(error) => format!("log_unavailable:{error}"),
                },
                Compiled::ComponentV2(component) => match open_log(&installed.name) {
                    Ok(log) => crate::service_components_v2::run_once(&installed, &grant, component, &thread_shared, log),
                    Err(error) => format!("log_unavailable:{error}"),
                },
            };
            crate::node_telemetry::record_component_run(
                &installed.name,
                run_start_ms,
                began.elapsed().as_micros() as u64,
                outcome == "exit_0",
            );
            *thread_shared.last_exit.lock().unwrap() = outcome.clone();
            if thread_shared.stop.load(Ordering::Relaxed) {
                set(&thread_shared, "stopped");
                crate::node_telemetry::record_service_health(&installed.name, false);
                return;
            }
            if began.elapsed() > HEALTHY {
                backoff = Duration::from_secs(1);
            }
            thread_shared.restarts.fetch_add(1, Ordering::Relaxed);
            // Why a restart happened, from a closed set so the label cannot carry an error text.
            crate::node_telemetry::record_service_restart(&installed.name, crate::node_telemetry::restart_reason(&outcome));
            set(&thread_shared, "backoff");
            let until = Instant::now() + backoff;
            while Instant::now() < until {
                if thread_shared.stop.load(Ordering::Relaxed) {
                    set(&thread_shared, "stopped");
                    crate::node_telemetry::record_service_health(&installed.name, false);
                    return;
                }
                std::thread::sleep(Duration::from_millis(100));
            }
            backoff = (backoff * 2).min(BACKOFF_MAX);
        }
    });
    match thread {
        Ok(thread) => {
            services.insert(name.clone(), Handle { shared, sha256: sha256.clone(), thread: Some(thread) });
            json!({
                "ok": true,
                "name": name,
                "started": true,
                "sha256": sha256,
                "state": state.to_json(),
                "grants": {
                    "bus": {"publish": bus_grants.publish, "subscribe": bus_grants.subscribe},
                    "queue": queue_grants.to_json(),
                },
            })
        }
        Err(error) => json!({"ok": false, "error": format!("spawn_failed:{error}")}),
    }
}

/// Stop a service and wait for it (grace for a clean exit, then the epoch traps it).
pub fn stop(name: &str) -> Value {
    let handle = registry().lock().unwrap().remove(name);
    // Revocable registrations (`docs/BUS.md`, "Revocation"; `docs/QUEUE.md`, item 4): a stopped
    // component is never handed one more event, and its queue grant stops applying. This runs for a
    // component that was not running too - a grant without a process is exactly what must not
    // linger - and it is cheap and idempotent.
    let bus_revoked = crate::bus_host::unregister(name);
    crate::queue_host::node().unregister(name);
    let Some(mut handle) = handle else {
        return json!({"ok": true, "name": name, "was_running": false, "bus_subscriptions_revoked": bus_revoked});
    };
    handle.shared.stop.store(true, Ordering::Relaxed);
    if let Some(thread) = handle.thread.take() {
        let _ = thread.join();
    }
    // The supervisor sets this itself when it returns; repeating it here covers a stop that raced
    // with a start and never reached the loop's stop branch.
    crate::node_telemetry::record_service_health(name, false);
    json!({
        "ok": true,
        "name": name,
        "was_running": true,
        "last_exit": *handle.shared.last_exit.lock().unwrap(),
        "bus_subscriptions_revoked": bus_revoked,
    })
}

fn describe(name: &str, handle: &Handle) -> Value {
    let s = &handle.shared;
    json!({
        "name": name,
        "state": *s.state.lock().unwrap(),
        "sha256": handle.sha256,
        "restarts": s.restarts.load(Ordering::Relaxed),
        "sockets": s.sockets.load(Ordering::Relaxed),
        "started_at": s.started_at.load(Ordering::Relaxed),
        "last_exit": *s.last_exit.lock().unwrap(),
        "health": *s.health.lock().unwrap(),
    })
}

pub fn status(name: Option<&str>) -> Value {
    let services = registry().lock().unwrap();
    match name {
        Some(name) => services.get(name).map(|h| describe(name, h)).unwrap_or_else(|| json!({"name": name, "state": "not_running"})),
        None => {
            let mut list: Vec<Value> = services.iter().map(|(n, h)| describe(n, h)).collect();
            list.sort_by(|a, b| a["name"].as_str().cmp(&b["name"].as_str()));
            json!(list)
        }
    }
}

/// The last `bytes` of a service's log (stdout + stderr).
pub fn logs(name: &str, bytes: u64) -> Value {
    if load(name).is_err() && std::fs::metadata(log_path(name)).is_err() {
        return json!({"ok": false, "error": "service_unknown"});
    }
    let Ok(mut file) = std::fs::File::open(log_path(name)) else { return json!({"ok": true, "name": name, "log": ""}) };
    let len = file.metadata().map(|m| m.len()).unwrap_or(0);
    let want = bytes.clamp(1, 256 << 10);
    let _ = std::io::Seek::seek(&mut file, std::io::SeekFrom::Start(len.saturating_sub(want)));
    let mut text = String::new();
    let mut raw = Vec::new();
    let _ = file.read_to_end(&mut raw);
    text.push_str(&String::from_utf8_lossy(&raw));
    json!({"ok": true, "name": name, "bytes": len, "log": text})
}

/// host.service(request_json): {action: start|stop|status|logs, name, ...grant}.
pub extern "C-unwind" fn service(l: *mut wa_host_support::lua::LuaState) -> std::os::raw::c_int {
    let raw = wa_host_support::lua::arg_string(l, 1).unwrap_or_default();
    let answer = match serde_json::from_str::<Value>(&raw) {
        Ok(request) => {
            let name = request.get("name").and_then(Value::as_str);
            match request.get("action").and_then(Value::as_str).unwrap_or_default() {
                "start" => start(&request),
                "stop" => name.map(stop).unwrap_or_else(|| json!({"ok": false, "error": "service_name_required"})),
                "status" => status(name),
                "logs" => name
                    .map(|n| logs(n, request.get("bytes").and_then(Value::as_u64).unwrap_or(16 << 10)))
                    .unwrap_or_else(|| json!({"ok": false, "error": "service_name_required"})),
                _ => json!({"ok": false, "error": "invalid_service_action"}),
            }
        }
        Err(_) => json!({"ok": false, "error": "invalid_service_request"}),
    };
    wa_host_support::json::push_json(l, &answer);
    1
}

/// Test support shared by the service runner tests: the gate builds the fixtures with
/// `scripts/build-components.sh` into one directory (`WA_TEST_SERVICE_DIR`), and each test copies
/// what it needs into a private component directory, because `WA_COMPONENTS_DIR` is process-global
/// and every one of these tests runs a real service.
#[cfg(test)]
pub(crate) mod support {
    use super::*;

    /// Install the fixtures named in `wanted` into a private components dir and point
    /// `WA_COMPONENTS_DIR` at it. `None` when the gate did not build them (the caller skips).
    pub(crate) fn install(suffix: &str, wanted: &[&str]) -> Option<std::path::PathBuf> {
        let source = std::path::PathBuf::from(std::env::var("WA_TEST_SERVICE_DIR").ok()?);
        let dir = std::env::temp_dir().join(format!("wa-services-{}-{suffix}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).ok()?;
        for name in wanted {
            let mut copied = 0;
            for extension in ["wasm", "wasm.sha256", "json"] {
                let from = source.join(format!("{name}.{extension}"));
                if from.is_file() && std::fs::copy(&from, dir.join(format!("{name}.{extension}"))).is_ok() {
                    copied += 1;
                }
            }
            if copied != 3 {
                return None; // a fixture the gate did not build is a skip, never a pass
            }
        }
        std::env::set_var("WA_COMPONENTS_DIR", &dir);
        Some(dir)
    }

    /// A local HTTP server that answers every request with `200` and `body`, so a granted `net`
    /// dial has a real peer. Returns its port.
    pub(crate) fn http_echo(body: &'static str) -> u16 {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                std::thread::spawn(move || {
                    let mut stream = stream;
                    let mut request = [0u8; 4096];
                    let _ = stream.read(&mut request);
                    let response = format!(
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n{}",
                        body.len(),
                        body
                    );
                    let _ = stream.write_all(response.as_bytes());
                });
            }
        });
        port
    }

    /// A local websocket server that echoes the first binary frame it receives (tungstenite's own
    /// server handshake, the peer of the client the host speaks). Returns its port.
    pub(crate) fn ws_echo() -> u16 {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                std::thread::spawn(move || {
                    let Ok(mut socket) = tungstenite::accept(stream) else { return };
                    socket.get_mut().set_read_timeout(Some(Duration::from_secs(10))).ok();
                    if let Ok(tungstenite::Message::Binary(frame)) = socket.read() {
                        let _ = socket.send(tungstenite::Message::Binary(frame));
                    }
                    let _ = socket.close(None);
                });
            }
        });
        port
    }

    /// Wait until the service log contains `needle`, or give up. Returns the whole log either way.
    pub(crate) fn wait_for_log(name: &str, needle: &str, within: Duration) -> String {
        let deadline = Instant::now() + within;
        loop {
            let text = logs(name, 16 << 10)["log"].as_str().unwrap_or("").to_string();
            if text.contains(needle) || Instant::now() >= deadline {
                return text;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dial_allowlist_exact_and_suffix() {
        let granted = vec!["web.whatsapp.com:443".to_string(), "*.whatsapp.net:443".to_string()];
        assert!(dial_allowed(&granted, "web.whatsapp.com:443"));
        assert!(dial_allowed(&granted, "mmg.whatsapp.net:443"));
        assert!(dial_allowed(&granted, "MEDIA-GRU1-1.cdn.whatsapp.net:443"));
        assert!(!dial_allowed(&granted, "whatsapp.net:443"), "the bare suffix is not a subdomain");
        assert!(!dial_allowed(&granted, "evilwhatsapp.net:443"));
        assert!(!dial_allowed(&granted, "mmg.whatsapp.net:80"));
        assert!(!dial_allowed(&granted, "web.whatsapp.com:443/x"));
        assert!(!dial_allowed(&granted, "example.com:443"));
        assert!(!dial_allowed(&[], "web.whatsapp.com:443"));
    }

    /// End to end with the wasip1 core-module fixture (`svc-echo-wasip1`): heartbeat, a granted
    /// dial to a local echo server, a refused dial, stop within the grace, crash restart. The
    /// wa:kernel fixtures prove the same runner contract through their own tests
    /// (`service_components::tests`, `service_components_v2::tests`).
    #[test]
    fn fixture_service_runs_dials_and_stops() {
        let _dir = crate::components::TEST_DIR_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        if support::install("wasip1", &["svc-echo-wasip1"]).is_none() {
            return;
        }
        let name = "svc-echo-wasip1";
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                let mut s = stream;
                let mut buf = [0u8; 64];
                if let Ok(n) = s.read(&mut buf) {
                    let _ = s.write_all(&buf[..n]);
                }
            }
        });
        let config = json!({"dial": format!("127.0.0.1:{port}"), "refused": "127.0.0.2:9"});
        let started = start(&json!({"name": name, "net": [format!("127.0.0.1:{port}")], "config": config}));
        assert_eq!(started["ok"], true, "{started}");
        assert_eq!(start(&json!({"name": name, "net": [format!("127.0.0.1:{port}")], "config": config}))["already_running"], true);
        std::thread::sleep(Duration::from_millis(1500));
        let log = logs(name, 4096)["log"].as_str().unwrap_or("").to_string();
        assert!(log.contains("heartbeat"), "{log}");
        assert!(log.contains("echo ok"), "{log}");
        assert!(log.contains("refused -13"), "{log}");
        assert_eq!(status(Some(name))["state"], "running");
        let t = Instant::now();
        let stopped = stop(name);
        assert_eq!(stopped["was_running"], true);
        assert!(t.elapsed() < STOP_GRACE + Duration::from_secs(2));
        assert_eq!(status(Some(name))["state"], "not_running");
        // Crash mode: exits non-zero; the supervisor restarts it.
        let crash = json!({"crash": true});
        assert_eq!(start(&json!({"name": name, "config": crash}))["ok"], true);
        std::thread::sleep(Duration::from_millis(2500));
        let s = status(Some(name));
        assert!(s["restarts"].as_u64().unwrap_or(0) >= 1, "{s}");
        assert!(s["last_exit"].as_str().unwrap_or("").starts_with("exit_3"), "{s}");
        stop(name);
        // A grant beyond the manifest is refused before anything runs.
        let wide = start(&json!({"name": name, "net": ["10.0.0.1:443"]}));
        assert!(wide["error"].as_str().unwrap_or("").contains("not_declared"), "{wide}");
    }
}
