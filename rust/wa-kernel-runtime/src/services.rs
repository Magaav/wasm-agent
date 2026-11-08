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
use anyhow::Result;
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
    /// This instance's identity (`name#generation`): what its registrations are keyed by. Set once, in
    /// `spawn_instance`, before the thread that could register anything exists.
    pub(crate) instance: OnceLock<crate::registrations::Instance>,
    pub(crate) stop: AtomicBool,
    /// A hot swap is replacing this instance: take no new work, finish the one in hand, report `idle`
    /// (`wa:kernel/drain`, `drain::retire`). Set by `services::replace` and by nothing else - a plain
    /// `stop` keeps meaning "stop now", so a component that never imported the drain signal is
    /// stopped exactly as it was before the signal existed.
    pub(crate) draining: AtomicBool,
    /// The guest answered `draining` with "nothing in flight" (`wa:kernel/drain.idle`). Once set, the
    /// instance is stopping and is never restarted: a drained run that returns cleanly would
    /// otherwise look like a crash to the supervisor's restart loop.
    pub(crate) idle: AtomicBool,
    /// Last `lifecycle.report` from a component service ("" for wasip1 modules).
    pub(crate) health: Mutex<String>,
    restarts: AtomicU64,
    sockets: AtomicU64,
    /// `starting`, `running`, `backoff`, `stopped`: read by `status` and by the dev swap.
    pub(crate) state: Mutex<String>,
    /// The outcome of the run that ended (`exit_0`, `trap:…`), which is what a dev swap refuses on.
    pub(crate) last_exit: Mutex<String>,
    started_at: AtomicU64,
}

struct Handle {
    shared: Arc<Shared>,
    sha256: String,
    thread: Option<std::thread::JoinHandle<()>>,
    /// The generation of the instance this handle owns: what `replace` revokes when it retires it.
    generation: u64,
    /// The instance's drain hook (`Spawned::drain_aware`): what `replace` reads to decide whether
    /// waiting for the work in flight is meaningful.
    drain_aware: bool,
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

/// One line appended to a service's log by the host itself (a drain outcome, not a guest line). The
/// guest holds the same file for its own stdout, so this only ever appends; a log that cannot be
/// opened loses the line and nothing else - a swap must not fail because a file did.
fn append_log(name: &str, line: &str) {
    if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(log_path(name)) {
        let _ = writeln!(file, "{line}");
    }
}

fn open_log(name: &str) -> Result<std::fs::File> {
    // Bounded store (store.rs): a service log has a per-component quota, applied at start - the one
    // moment the host owns the file. While the service runs the guest holds the handle, so the
    // sweep alerts at 80 % instead of rotating a file out from under it.
    wa_governance::store::enforce_service_log(&crate::components::component_dir(), name, wa_governance::store::service_log_quota());
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
    // Declared in the manifest, capped by the node: the same resolution the two component runners use
    // (`crate::limits`), so the same manifest cannot yield two memory caps.
    let effective_limits = crate::limits::for_service(installed);
    let memory_mb = effective_limits.memory_mb;
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
    // The stop grace and the CPU budget (`limits.cpu_ms` of execution in one window, then a trap),
    // the same two rules the two component runners apply.
    let mut cpu = wa_governance::component_limits::CpuBudget::new(effective_limits.cpu_ms, Instant::now());
    store.epoch_deadline_callback(move |_| {
        let now = Instant::now();
        if watcher.stop.load(Ordering::Relaxed) {
            let mut seen = stop_seen.lock().unwrap();
            let since = *seen.get_or_insert(now);
            if since.elapsed() > STOP_GRACE {
                return Err(wasmtime::Error::msg("service_stopped"));
            }
        }
        if cpu.sample(now) {
            return Err(wasmtime::Error::msg("cpu_limit"));
        }
        Ok(UpdateDeadline::Continue(1))
    });
    store.set_epoch_deadline(1);
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
    let spawned = match spawn_instance(installed, grant) {
        Ok(spawned) => spawned,
        Err(error) => return error,
    };
    let report = spawned.report.clone();
    let sha256 = spawned.sha256.clone();
    let instance = spawned.instance.clone();
    services.insert(
        name.clone(),
        Handle {
            shared: spawned.shared,
            sha256: sha256.clone(),
            thread: spawned.thread,
            generation: instance.generation,
            drain_aware: spawned.drain_aware,
        },
    );
    // A provider that just came up can let something that was waiting for it start. The supervisor
    // owns that decision (`supervisor::kick`), not this function.
    drop(services);
    crate::supervisor::note_started(&name);
    crate::supervisor::kick();
    let mut answer = json!({"ok": true, "name": name, "started": true, "sha256": sha256, "instance": instance.to_json()});
    for (key, value) in report.as_object().into_iter().flatten() {
        answer[key] = value.clone();
    }
    answer
}

/// One supervised instance, not in the registry: the dev-loop hook below starts two of these at
/// once (the new pin beside the old one) and stops whichever loses.
pub(crate) struct Spawned {
    pub(crate) name: String,
    pub(crate) shared: Arc<Shared>,
    pub(crate) sha256: String,
    pub(crate) thread: Option<std::thread::JoinHandle<()>>,
    /// This instance's identity (`name#generation`): what a swap revokes, and what the start answer and
    /// `/health` name.
    pub(crate) instance: crate::registrations::Instance,
    /// What `start` puts in its answer besides the name: `state`, `grants` and `limits`.
    pub(crate) report: Value,
    /// Does this artifact implement `wa:kernel/drain@0.2.0` (read from its own imports)? A swap only
    /// waits for an instance that said it would finish its work (`drain::retire`).
    pub(crate) drain_aware: bool,
}

/// The instance token a runner's guest calls carry (`name#generation`), or the plain name for a store
/// built without one (a unit test that drives a runner directly).
pub(crate) fn instance_token(shared: &Arc<Shared>, name: &str) -> String {
    shared.instance.get().map(|instance| instance.token.clone()).unwrap_or_else(|| name.to_string())
}

/// Compile and start one instance of an already-verified component.
///
/// Extracted from `start` so that a hot swap runs exactly the code a cold start runs (grants,
/// state migration, contract detection, log, supervision) instead of a second, drifting copy.
/// Everything that identifies *which* instance to stop later stays with the caller.
pub(crate) fn spawn_instance(installed: Installed, grant: Grant) -> std::result::Result<Spawned, Value> {
    let name = installed.name.clone();
    // The transactional install (docs/STATE.md): before anything is compiled or started, a
    // manifest that declares `state_version` must find its namespace at that version. The migration
    // runs on a snapshot copy and is swapped in only if it succeeds; a refusal here leaves the
    // previous instance and its state exactly as they were, and nothing has started.
    let state = match crate::state_host::prepare_install(&installed) {
        Ok(outcome) => outcome,
        Err(error) => return Err(json!({"ok": false, "name": name, "error": error})),
    };
    // The two component-facing providers' grants, read from the same (already checked) manifest:
    // `bus` patterns and `queue` interfaces/namespaces. A malformed grant is a refusal here, before
    // anything runs; a component that declares neither gets no bus grant and no queue interface, so
    // every call it makes on them is refused by the ACL/gate rather than silently allowed.
    let bus_grants = match crate::bus_host::register(&name, &installed.manifest) {
        Ok(grants) => grants,
        Err(error) => return Err(json!({"ok": false, "name": name, "error": error})),
    };
    let queue_grants = match crate::queue_host::node().register(&name, &installed.manifest) {
        Ok(grants) => grants,
        Err(error) => return Err(json!({"ok": false, "name": name, "error": error})),
    };
    let engine = match crate::components::engine() {
        Ok(engine) => engine,
        Err(error) => return Err(json!({"ok": false, "error": error.to_string()})),
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
            Err(error) => return Err(json!({"ok": false, "error": format!("engine_failed:{error}")})),
        };
        // Cached by pin: a hot swap starts the same bytes beside the running instance, and compiling
        // an 8 MB component twice for one upgrade is time nobody asked to pay (`compiled`).
        let probe = match crate::service_components_v2::compiled(&async_engine, &installed.sha256, &installed.bytes) {
            Ok(component) => component,
            Err(error) => return Err(json!({"ok": false, "error": format!("compile_failed:{error}")})),
        };
        match crate::service_components_v2::Contract::of(&probe) {
            crate::service_components_v2::Contract::V2 => Compiled::ComponentV2(probe),
            crate::service_components_v2::Contract::V1 => match wasmtime::component::Component::new(&engine, &installed.bytes) {
                Ok(c) => Compiled::Component(c),
                Err(error) => return Err(json!({"ok": false, "error": format!("compile_failed:{error}")})),
            },
        }
    } else {
        match Module::new(&engine, &installed.bytes) {
            Ok(m) => Compiled::Module(m),
            Err(error) => return Err(json!({"ok": false, "error": format!("compile_failed:{error}")})),
        }
    };
    // Everything that identifies which instance this is, and the two provider grants keyed by it, are
    // opened *before* the thread exists: a guest cannot have registered anything yet, so there is no
    // window in which a call arrives with no instance to attribute it to.
    let instance = crate::registrations::node().open_instance(&name);
    let instance_limits = crate::limits::for_service(&installed);
    let shared = Arc::new(Shared::default());
    shared.instance.set(instance.clone()).ok();
    set(&shared, "starting");
    // The provider rows this instance owns, and how they are revoked. The ledger runs each cancel when
    // the instance is revoked (stop or replacement); the bus and the queue do the revocation itself.
    crate::bus_host::node().attach(&name, &instance.token);
    if let Err(error) = crate::queue_host::node().register_instance(&name, &instance.token, &installed.manifest) {
        return Err(json!({"ok": false, "error": error}));
    }
    {
        let ledger = crate::registrations::node();
        let bus_token = instance.token.clone();
        let queue_token = instance.token.clone();
        ledger.register(
            &instance,
            crate::registrations::Kind::BusSubscription,
            &format!("instance {bus_token}"),
            Some(Box::new(move || {
                crate::bus_host::node().detach(&bus_token);
            })),
        );
        ledger.register(
            &instance,
            crate::registrations::Kind::QueueConsumer,
            &format!("grants for {queue_token}"),
            Some(Box::new(move || {
                crate::queue_host::node().unregister_instance(&queue_token);
            })),
        );
    }
    // The drain hook, read from the artifact and not from a manifest field: a 0.2 guest that imports
    // `wa:kernel/drain@0.2.0` finishes the job in hand before it stops (`drain::retire`). Everything
    // else - the wasip1 modules, the 0.1 components, a 0.2 component that did not opt in - is stopped
    // immediately, exactly as before.
    let drain_aware = match &compiled {
        Compiled::ComponentV2(component) => crate::service_components_v2::drains(component),
        _ => false,
    };
    let thread_shared = shared.clone();
    let sha256 = installed.sha256.clone();
    let thread = std::thread::Builder::new().name(format!("wa-service-{name}")).spawn(move || {
        let mut backoff = Duration::from_secs(1);
        loop {
            set(&thread_shared, "running");
            // Health is a gauge, not a log line: 1 while a run is in flight, 0 when the supervisor
            // stops for good (docs/TELEMETRY.md).
            wa_governance::node_telemetry::record_service_health(&installed.name, true);
            thread_shared.started_at.store(now(), Ordering::Relaxed);
            let run_start_ms = wa_governance::node_telemetry::now_ms();
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
            wa_governance::node_telemetry::record_component_run(
                &installed.name,
                run_start_ms,
                began.elapsed().as_micros() as u64,
                outcome == "exit_0",
            );
            *thread_shared.last_exit.lock().unwrap() = outcome.clone();
            // `stop` is the kernel's, `idle` is the guest's: an instance that said it had nothing in
            // flight and returned is a *drained* instance, on its way out. Restarting it would put two
            // instances of one component on the same queue, which is the bug a swap exists to avoid.
            if thread_shared.stop.load(Ordering::Relaxed) || thread_shared.idle.load(Ordering::Relaxed) {
                set(&thread_shared, "stopped");
                wa_governance::node_telemetry::record_service_health(&installed.name, false);
                return;
            }
            if began.elapsed() > HEALTHY {
                backoff = Duration::from_secs(1);
            }
            thread_shared.restarts.fetch_add(1, Ordering::Relaxed);
            // Why a restart happened, from a closed set so the label cannot carry an error text.
            wa_governance::node_telemetry::record_service_restart(&installed.name, wa_governance::node_telemetry::restart_reason(&outcome));
            set(&thread_shared, "backoff");
            let until = Instant::now() + backoff;
            while Instant::now() < until {
                if thread_shared.stop.load(Ordering::Relaxed) || thread_shared.idle.load(Ordering::Relaxed) {
                    set(&thread_shared, "stopped");
                    wa_governance::node_telemetry::record_service_health(&installed.name, false);
                    return;
                }
                std::thread::sleep(Duration::from_millis(100));
            }
            backoff = (backoff * 2).min(BACKOFF_MAX);
        }
    });
    match thread {
        Ok(thread) => Ok(Spawned {
            name: name.clone(),
            shared,
            sha256,
            thread: Some(thread),
            instance,
            drain_aware,
            report: json!({
                "state": state.to_json(),
                "grants": {
                    "bus": {"publish": bus_grants.publish, "subscribe": bus_grants.subscribe},
                    "queue": queue_grants.to_json(),
                },
                // What this instance actually got, and which side decided: a component given less than
                // its manifest asked for can see why without comparing numbers by hand.
                "limits": {
                    "memory_mb": instance_limits.memory_mb,
                    "cpu_ms": instance_limits.cpu_ms,
                    "by": instance_limits.by,
                },
            }),
        }),
        Err(error) => Err(json!({"ok": false, "error": format!("spawn_failed:{error}")})),
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
    // The ledger's own rows: every generation of this name, so a stop that follows a swap cannot leave
    // the loser's registrations behind.
    let registrations_revoked = crate::registrations::node().revoke_owner(name);
    // A stopped definition is not wanted any more: without this, the next reconcile would start it
    // again (an operator's `stop` is not a hint). `enable`/`autostart`/`supervise` re-register it.
    crate::supervisor::forget(name);
    let Some(mut handle) = handle else {
        crate::supervisor::note_stopped(name);
        crate::supervisor::kick();
        return json!({
            "ok": true, "name": name, "was_running": false,
            "bus_subscriptions_revoked": bus_revoked,
            "registrations_revoked": registrations_revoked,
        });
    };
    handle.shared.stop.store(true, Ordering::Relaxed);
    if let Some(thread) = handle.thread.take() {
        let _ = thread.join();
    }
    // The supervisor sets this itself when it returns; repeating it here covers a stop that raced
    // with a start and never reached the loop's stop branch.
    wa_governance::node_telemetry::record_service_health(name, false);
    crate::supervisor::note_stopped(name);
    crate::supervisor::kick();
    json!({
        "ok": true,
        "name": name,
        "was_running": true,
        "last_exit": *handle.shared.last_exit.lock().unwrap(),
        "bus_subscriptions_revoked": bus_revoked,
        "registrations_revoked": registrations_revoked,
    })
}

/// Stop an instance that never entered the registry (a candidate an upgrade refused), and revoke
/// exactly its own registrations. Returns its last run outcome.
pub(crate) fn stop_spawned(mut spawned: Spawned) -> String {
    spawned.shared.stop.store(true, Ordering::Relaxed);
    if let Some(thread) = spawned.thread.take() {
        let _ = thread.join();
    }
    crate::registrations::node().revoke_generation(&spawned.name, spawned.instance.generation);
    let last = spawned.shared.last_exit.lock().unwrap().clone();
    last
}

/// Replace the registry's instance for `name` with one that was started beside it, revoke exactly the
/// instance that lost, and stop it. The caller (`install::upgrade`, `dev::swap`) has already proved the
/// candidate healthy; this is the switch.
///
/// The revocation is per **generation**, not per name: the old instance's bus subscriptions and queue
/// grants go (its `cancel`s in the ledger run), the new instance's rows - registered under its own
/// token before this call - stay. A name-keyed revoke here is exactly the bug this exists to prevent.
///
/// The old instance's leases are handed over before they are revoked: a job it was running is neither
/// failed nor left to lose its lease, so a queue with pending work survives a swap with nothing lost
/// and nothing duplicated (`wa_queue::Queue::handover`, `QueueHost::handover_instance`).
///
/// **The drain comes first** (`drain::retire`, `wit/kernel-v2/kernel.wit`'s `interface drain`). Handing
/// a lease back is the right shape for a crash, but a swap is not a crash: a job that was half-applied
/// when the instance stopped is retried by the replacement, and "at-least-once" is the wrong bill for
/// an upgrade an operator asked for. So a component that implements the drain is *asked* first - it
/// finishes the `handle` in hand, settles it, reports idle - and only then is it stopped. A component
/// without the hook, one with nothing in flight, and one that misses the deadline all take the old
/// path; the swap answer and the component's own log say which case it was (`draining` below).
pub(crate) fn replace(name: &str, candidate: Spawned) -> Value {
    let previous = registry().lock().unwrap().insert(
        name.to_string(),
        Handle {
            shared: candidate.shared.clone(),
            sha256: candidate.sha256.clone(),
            thread: candidate.thread,
            generation: candidate.instance.generation,
            drain_aware: candidate.drain_aware,
        },
    );
    let retired = match previous {
        Some(mut old) => {
            let token = format!("{name}#{}", old.generation);
            // Read the leases *before* the drain: after it they are settled, which is the whole point.
            let queue = crate::queue_host::node();
            let token_for_count = token.clone();
            let draining = crate::drain::retire(&old.shared, old.drain_aware, move || queue.in_flight_instance(&token_for_count), crate::drain::deadline());
            old.shared.stop.store(true, Ordering::Relaxed);
            if let Some(thread) = old.thread.take() {
                let _ = thread.join();
            }
            // The in-flight jobs of the instance that just stopped go back to `Ready`, due now, before
            // anything is revoked: they were not failed (a swap is not a crash), and the instance that
            // replaced this one is already polling `take`. This runs *after* the join, so nothing of the
            // old instance can still be running the work that is being handed over.
            let handed_over = crate::queue_host::node().handover_instance(&token);
            let revoked = crate::registrations::node().revoke_generation(name, old.generation);
            // Belt and braces for a provider whose rows were not in the ledger (a caller that registered
            // through the provider directly): only the retired generation's token is revoked here.
            crate::bus_host::node().detach(&format!("{name}#{}", old.generation));
            crate::queue_host::node().unregister_instance(&format!("{name}#{}", old.generation));
            // What the swap did, in the retired component's own log: "why was my job retried" is the
            // question an operator asks after an upgrade, and the answer belongs where the run's own
            // lines are (`services logs <name>`), not only in whatever asked for the swap.
            append_log(name, &draining.log_line(handed_over));
            json!({
                "generation": old.generation,
                "last_exit": *old.shared.last_exit.lock().unwrap(),
                "registrations_revoked": revoked,
                // How many in-flight queue jobs were handed to the new instance instead of waiting for
                // their lease to lapse. A number somebody can read after a swap, not a claim.
                "queue_handed_over": handed_over,
                // Whether the retire waited for the work in hand, and why it stopped waiting.
                "drain": draining.to_json(),
            })
        }
        None => Value::Null,
    };
    crate::supervisor::note_started(name);
    crate::supervisor::kick();
    json!({"retired": retired, "instance": candidate.instance.to_json(), "sha256": candidate.sha256})
}

fn describe(name: &str, handle: &Handle) -> Value {
    let s = &handle.shared;
    let instance = s.instance.get();
    json!({
        "name": name,
        "state": *s.state.lock().unwrap(),
        "sha256": handle.sha256,
        "generation": handle.generation,
        "instance": instance.map(|instance| instance.token.clone()),
        "restarts": s.restarts.load(Ordering::Relaxed),
        "sockets": s.sockets.load(Ordering::Relaxed),
        "started_at": s.started_at.load(Ordering::Relaxed),
        "last_exit": *s.last_exit.lock().unwrap(),
        "health": *s.health.lock().unwrap(),
        // The drain hook, and whether this instance has been asked to drain: `cooperative` means a
        // swap waits for the work in hand, `immediate` means it stops the instance as it always did.
        "drain": if handle.drain_aware { "cooperative" } else { "immediate" },
        "draining": s.draining.load(Ordering::Relaxed),
        "idle": s.idle.load(Ordering::Relaxed),
        // The registrations this instance holds, so "nothing of the old one lingers" is a number
        // somebody can read after a swap, not a claim in a commit message.
        "registrations": instance.map(|i| crate::registrations::node().count_generation(name, i.generation)).unwrap_or(0),
    })
}

pub fn status(name: Option<&str>) -> Value {
    let services = registry().lock().unwrap();
    match name {
        Some(name) => {
            let mut answer = services.get(name).map(|h| describe(name, h)).unwrap_or_else(|| json!({"name": name, "state": "not_running"}));
            // A definition whose imports are not served is not "not running": it is waiting, and the
            // interface it waits for is the answer to "why".
            if let Some(waiting) = crate::supervisor::pending(name) {
                answer["state"] = json!("waiting");
                answer["waiting_for"] = waiting["waiting_for"].clone();
                answer["waiting_reason"] = waiting["reason"].clone();
            }
            answer
        }
        None => {
            let mut list: Vec<Value> = services.iter().map(|(n, h)| describe(n, h)).collect();
            for (name, waiting) in crate::supervisor::pending_entries() {
                if !list.iter().any(|row| row["name"].as_str() == Some(name.as_str())) {
                    list.push(json!({
                        "name": name,
                        "state": "waiting",
                        "waiting_for": waiting["waiting_for"].clone(),
                        "waiting_reason": waiting["reason"].clone(),
                    }));
                }
            }
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
                // The transactional install (`docs/KERNEL.md`, lesson 5): stage, verify, check imports,
                // migrate, start beside, health, switch, stop. Any failure leaves the old instance
                // running and its files untouched (`install::upgrade`).
                "upgrade" => crate::install::upgrade(&request),
                // Profiles as layers (`docs/KERNEL.md`, lesson 4): the effective configuration after
                // base -> node -> user -> patch, rows by id.
                "profile_dump" => crate::profiles::dump(request.get("name").and_then(Value::as_str)),
                // Start by imports: reconcile a set of definitions against what is running, starting
                // everything whose imports are served and reporting what each other one waits for.
                "supervise" => crate::supervisor::reconcile(&request),
                "registrations" => json!(crate::registrations::node().status()),
                // The feature switches (docs/FEATURES.md): the same document `wa features` prints and
                // `host.features` answers, resolved live from policy.json by the one resolver. A
                // service answer, not a service control: it starts nothing and installs nothing.
                "features" => wa_features::node_value(),
                "limits" => json!({"node": crate::limits::caps().to_json()}),
                // The compute fabric (`docs/FABRIC.md`): the live view with each node's load and
                // capabilities, the recent placements and the score that decided them, the local
                // fallbacks by reason, and the leases the fabric queues carry. `configure`, `tick`,
                // `submit`, `take` and `settle` are the same surface for the node's own loop.
                "fabric" => crate::fabric_node::admin(&request),
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

    /// The CPU budget, end to end: a guest whose `_start` is `loop { br 0 }` is trapped once
    /// `limits.cpu_ms` of execution has been spent in a window. The budget is tiny here (the floor) so
    /// the test costs milliseconds; the *default* is 5 s precisely because a polling 0.1 guest is
    /// normal (`wa_governance::component_limits::DEFAULT_CPU_MS`).
    #[test]
    fn a_guest_that_never_yields_is_trapped_by_its_cpu_budget() {
        let _dir = crate::components::TEST_DIR_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = std::env::temp_dir().join(format!("wa-cpu-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::env::set_var("WA_COMPONENTS_DIR", &dir);
        let name = "spin-svc";
        let bytes = crate::test_wasm::spin_module();
        let sha = ring::digest::digest(&ring::digest::SHA256, &bytes).as_ref().iter().map(|b| format!("{b:02x}")).collect::<String>();
        let manifest = json!({"kind": "service", "target": "wasm32-wasip1", "limits": {"cpu_ms": 10}, "capabilities": {}});
        std::fs::write(dir.join(format!("{name}.wasm")), &bytes).unwrap();
        std::fs::write(dir.join(format!("{name}.wasm.sha256")), format!("{sha}
")).unwrap();
        std::fs::write(dir.join(format!("{name}.json")), manifest.to_string()).unwrap();
        let started = start(&json!({"name": name}));
        assert_eq!(started["ok"], true, "{started}");
        // The trap is recorded as the run's outcome and the supervisor backs off; wait for it rather
        // than for a fixed sleep, so a slow machine cannot turn this into a flake.
        let deadline = Instant::now() + Duration::from_secs(10);
        let mut last = String::new();
        while Instant::now() < deadline {
            last = status(Some(name))["last_exit"].as_str().unwrap_or("").to_string();
            if last.contains("cpu_limit") {
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(last.contains("cpu_limit"), "the cpu budget must trap the guest, last_exit={last}");
        let limits = &started["limits"];
        assert_eq!(limits["cpu_ms"], 10, "the manifest's budget is what the instance got: {limits}");
        assert_eq!(limits["by"], "manifest", "and the answer says the manifest decided");
        stop(name);
        let _ = std::fs::remove_dir_all(&dir);
    }

    // ---- the drained hot swap (docs/SERVICE-COMPONENTS.md, "A swap waits for the work in flight") ---
    //
    // The integration tests below drive the real `svc-drain` fixture: a wasm guest on
    // `wa:kernel@0.2` that consumes one job from `wa:queue/worker`, takes `handle_ms` over it, writes
    // one marker per job into its own kv, and settles it. The marker is the evidence: a job handled
    // twice leaves `2`, so "the swap completed it exactly once, with no second send" is a number in
    // the component's own store. `support::install` returns `None` when the gate did not build the
    // fixtures, and each test then says it skipped - it never passes by absence.

    /// The queue the fixture is granted (`svc-drain`'s `manifest.json`).
    const DRAIN_QUEUE: &str = "wa.drain";

    /// A candidate instance for a swap, built the way `install::upgrade` and `dev::swap` build one:
    /// the installed artifact and the same grant, started beside the registry's instance.
    fn candidate(name: &str, request: &Value) -> Spawned {
        let installed = load(name).expect("the fixture is installed");
        let grant = Grant::from_request(request).expect("grant");
        grant.check(&installed.manifest).expect("the manifest declares it");
        spawn_instance(installed, grant).expect("a candidate instance starts")
    }

    /// The node's queue for a component: the same handle the guest's `worker::take` goes through.
    fn queue_of(name: &str) -> wa_queue::Queue {
        crate::queue_host::node().queue(name)
    }

    /// Enqueue one job the way a node capability does, and return its id.
    fn enqueue(name: &str, payload: &[u8]) -> wa_queue::JobId {
        let queue = queue_of(name);
        let outcome = queue.enqueue(wa_queue::EnqueueRequest::new(DRAIN_QUEUE, payload.to_vec())).expect("enqueue");
        assert!(!outcome.dedupe_hit, "a fresh job");
        outcome.id
    }

    /// The fixture installed under a name of this test's own.
    ///
    /// The node's `QueueHost` is one per process and its directory is whichever components directory
    /// the first caller had, so two tests sharing an installed name would share a queue - and a job
    /// left leased by a test that failed would be taken by the next one instead of the job it just
    /// enqueued. The bytes, the manifest and the contract are the fixture's; only the installed name
    /// differs, which is also what makes the service log and the kv marker this test's own.
    fn install_as(dir: &std::path::Path, from: &str, to: &str) {
        for extension in ["wasm", "wasm.sha256", "json"] {
            std::fs::copy(dir.join(format!("{from}.{extension}")), dir.join(format!("{to}.{extension}")))
                .unwrap_or_else(|error| panic!("copy {from}.{extension} to {to}: {error}"));
        }
    }

    /// How many times the fixture handled `id`, from the component's own kv: the duplicate this whole
    /// design exists to prevent.
    fn handles(dir: &std::path::Path, name: &str, id: wa_queue::JobId) -> u32 {
        use wa_kv::Store as _;
        let store = crate::state_host::HostStore::at(crate::state_host::kv_path(dir, name));
        store
            .get(format!("handled/{}", id.0).as_bytes())
            .ok()
            .flatten()
            .and_then(|bytes| String::from_utf8(bytes).ok())
            .and_then(|text| text.parse().ok())
            .unwrap_or(0)
    }

    /// A job in the middle of its handle when the swap arrives. The drain finishes it, reports idle,
    /// and the kernel stops the instance with nothing to hand back: the job is settled **once**, by
    /// the instance that started it, and the replacement never sees it.
    #[test]
    fn a_swap_waits_for_the_job_in_hand_so_it_is_completed_exactly_once() {
        let _dir = crate::components::TEST_DIR_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let Some(fixtures) = support::install("drain-once", &["svc-drain"]) else { return };
        let name = "svc-drain-once";
        install_as(&fixtures, "svc-drain", name);
        stop(name);
        let id = enqueue(name, b"one send");
        let tag = format!("job={}", id.0);
        let request = json!({"name": name, "config": {"handle_ms": 2500, "tick_ms": 20}});
        assert_eq!(start(&request)["ok"], true);
        assert_eq!(status(Some(name))["drain"], "cooperative", "the fixture imports wa:kernel/drain");
        let log = support::wait_for_log(name, &format!("handling {tag}"), Duration::from_secs(20));
        assert!(log.contains(&format!("handling {tag}")), "the job is in hand: {log}");

        // The candidate is started first: what this measures is the swap, not a wasm compile.
        let next = candidate(name, &request);
        let began = Instant::now();
        let swapped = replace(name, next);
        let waited = began.elapsed();
        let drained = &swapped["retired"]["drain"];
        assert_eq!(drained["outcome"], "drained", "{swapped}");
        assert_eq!(swapped["retired"]["queue_handed_over"], 0, "nothing to hand back: {swapped}");
        assert!(waited >= Duration::from_millis(300), "the swap waited for the handle to finish: {waited:?}");
        assert!(waited < Duration::from_secs(5), "and not for the stop grace: {waited:?}");

        // The job: settled once, by the instance that took it, with its attempt budget untouched.
        let queue = queue_of(name);
        let job = queue.job(id).expect("load").expect("the job exists");
        assert_eq!(job.state, wa_queue::JobState::Done, "{job:?}");
        assert_eq!(job.attempts, 0, "a drained job was not retried");
        assert_eq!(job.lease_expiries, 0, "and its lease did not lapse");
        let stats = queue.stats(DRAIN_QUEUE).expect("stats");
        assert_eq!((stats.ready, stats.leased), (0, 0), "nothing left for the replacement: {stats:?}");
        assert_eq!(handles(&fixtures, name, id), 1, "the fixture handled this job exactly once");

        // Both halves of the story are in the component's log: the guest's own line and the host's.
        let log = logs(name, 16 << 10)["log"].as_str().unwrap_or("").to_string();
        assert!(log.contains("draining: idle, no work in flight"), "the guest said it was idle: {log}");
        assert!(log.contains("INFO drain: drained in"), "the host line says what the swap did: {log}");
        assert!(log.contains(&format!("settled {tag}")), "{log}");
        stop(name);
    }

    /// The deadline path: a guest that ignores the hook. After `WA_SERVICE_DRAIN_MS` the swap does
    /// exactly what it did before the drain existed - stop the instance, hand the lease back, let the
    /// replacement retry - and says so at WARN. The retry is the only settle, so the job still runs
    /// exactly once: the old instance is killed inside its handle and never settles.
    #[test]
    fn a_guest_that_never_reports_idle_falls_back_to_stop_and_retry_and_logs_it() {
        let _dir = crate::components::TEST_DIR_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let Some(fixtures) = support::install("drain-deadline", &["svc-drain"]) else { return };
        let name = "svc-drain-deadline";
        install_as(&fixtures, "svc-drain", name);
        stop(name);
        let id = enqueue(name, b"one send");
        let tag = format!("job={}", id.0);
        // The knob, not a constant: 400 ms keeps the test short. It is read by `drain::deadline`, so
        // the process-wide variable is set here and restored below, under the components-dir lock.
        let previous = std::env::var("WA_SERVICE_DRAIN_MS").ok();
        std::env::set_var("WA_SERVICE_DRAIN_MS", "400");
        let slow = json!({"name": name, "config": {"never_idle": true, "handle_ms": 60_000, "tick_ms": 20}});
        assert_eq!(start(&slow)["ok"], true);
        let log = support::wait_for_log(name, &format!("handling {tag}"), Duration::from_secs(20));
        assert!(log.contains(&format!("handling {tag}")), "the job is in hand: {log}");

        // The candidate is the cooperative mode: it is the one that finishes the handed-over job.
        let fast = json!({"name": name, "config": {"handle_ms": 100, "tick_ms": 20}});
        let next = candidate(name, &fast);
        let began = Instant::now();
        let swapped = replace(name, next);
        let waited = began.elapsed();
        // Restored as soon as the swap it shaped is over: a later assertion must not leave the knob
        // set for the other tests in this process.
        match previous {
            Some(value) => std::env::set_var("WA_SERVICE_DRAIN_MS", value),
            None => std::env::remove_var("WA_SERVICE_DRAIN_MS"),
        }
        let drained = &swapped["retired"]["drain"];
        assert_eq!(drained["outcome"], "deadline", "{swapped}");
        assert!(drained["waited_ms"].as_u64().unwrap_or(0) >= 400, "it waited the deadline: {swapped}");
        assert_eq!(swapped["retired"]["queue_handed_over"], 1, "the lease went back for a retry: {swapped}");
        // The stop grace is the runner's (`STOP_GRACE`) and a parked guest is dropped at its end.
        assert!(waited >= Duration::from_secs(2), "the stop path ran, not a drain: {waited:?}");

        let queue = queue_of(name);
        let deadline = Instant::now() + Duration::from_secs(20);
        let mut job = queue.job(id).expect("load").expect("the job exists");
        while Instant::now() < deadline && job.state != wa_queue::JobState::Done {
            std::thread::sleep(Duration::from_millis(50));
            job = queue.job(id).expect("load").expect("the job exists");
        }
        assert_eq!(job.state, wa_queue::JobState::Done, "the replacement ran it: {job:?}");
        assert_eq!(job.attempts, 0, "a handover is not a failure, so the retry spent no attempt");
        assert_eq!(handles(&fixtures, name, id), 1, "the old instance was killed mid-handle: one handle, one settle");

        let log = logs(name, 16 << 10)["log"].as_str().unwrap_or("").to_string();
        assert!(log.contains("WARN drain: deadline exceeded after"), "the fallback is logged, not silent: {log}");
        assert!(log.contains("handed 1 lease(s) back"), "{log}");
        assert!(log.contains(&format!("settled {tag}")), "{log}");
        stop(name);
    }

    /// A component without the hook - `svc-echo` does not import `wa:kernel/drain` - is stopped
    /// immediately and its work handed back, exactly as every swap behaved before the drain existed.
    /// That is the cost the drain must never charge a component that cannot take part.
    #[test]
    fn a_component_without_the_hook_is_stopped_at_once_as_before() {
        let _dir = crate::components::TEST_DIR_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        if support::install("drain-nohook", &["svc-echo"]).is_none() {
            return;
        }
        let name = "svc-echo";
        stop(name);
        let request = json!({"name": name, "config": {"tick_ms": 50}});
        assert_eq!(start(&request)["ok"], true);
        let log = support::wait_for_log(name, "heartbeat start", Duration::from_secs(20));
        assert!(log.contains("heartbeat start"), "{log}");
        assert_eq!(status(Some(name))["drain"], "immediate", "no drain hook in this artifact");

        let next = candidate(name, &request);
        let began = Instant::now();
        let swapped = replace(name, next);
        let waited = began.elapsed();
        assert_eq!(swapped["retired"]["drain"]["outcome"], "no_hook", "{swapped}");
        assert_eq!(swapped["retired"]["drain"]["waited_ms"], 0, "nothing was waited for: {swapped}");
        assert!(waited < Duration::from_secs(3), "no drain delay on top of the stop: {waited:?}");
        // The swap itself is unchanged: the new generation is the registry's instance and is running.
        assert_eq!(status(Some(name))["state"], "running");
        assert_ne!(status(Some(name))["generation"], swapped["retired"]["generation"]);
        let log = logs(name, 16 << 10)["log"].as_str().unwrap_or("").to_string();
        assert!(log.contains("no wa:kernel/drain hook in this artifact"), "{log}");
        stop(name);
    }
}
