//! Rendezvous **and relay**.
//!
//! Two jobs for nodes that cannot accept inbound connections (NAT, no public
//! address):
//!
//! * **Rendezvous** — a registry binding `node_id → {public_key, endpoints}`.
//!   Nodes bind by ed25519 key, never by address.
//! * **Relay** — store-and-forward for traffic addressed to a node that is
//!   attached by long-poll. The attached node dials *out* only, so it works
//!   behind any NAT; the relay hands it requests and returns its responses.
//!
//! Every call is signed by the node key: `action|node_id|ts`.
use crate::node;
mod bindings;
use rusqlite::Connection;
use serde_json::{json, Value};
use std::collections::{HashMap, VecDeque};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant};

const ONLINE_WINDOW: i64 = 180; // seconds
// A registration nobody has heartbeated for this long is removed. Without it the registry only ever
// grew: a scratch home, a deleted worktree or a reinstall leaves a row whose key no longer exists, and
// only that key may `/forget` itself - so the row stayed listed forever (26 rows, 4 real nodes, 04/11).
// Removing a row loses nothing: a live node re-registers on its next heartbeat, its granted role lives
// in `network_roles` and its binding in the binding tables. Admins are never pruned.
// `WA_RENDEZVOUS_RETENTION_SECONDS` overrides it; 0 keeps every row.
const DEFAULT_RETENTION: i64 = 7 * 24 * 3600;
const POLL_WAIT: Duration = Duration::from_secs(25);
const SEND_WAIT: Duration = Duration::from_secs(45);
// How long to hold a request for a node that is not attached at all. The node
// attaches by polling, so waiting is usually just waiting for the next poll -
// and failing immediately turned a four-second pause into a failed build.
const ATTACH_HOLD: Duration = Duration::from_secs(20);
/// How recently a node must have polled to count as attached. One number for every reader - the
/// send gate, `/lookup`, `/relay/status` and the attach/detach log - so none of them can disagree
/// about whether a node is reachable.
const ATTACH_WINDOW: Duration = Duration::from_secs(40);
/// How often the registry looks for a node that stopped polling. A detach is otherwise silent: a
/// node stopped, a link died, and nothing else would ever report it (measured 2026-11-10: a node was
/// `node_not_attached` for four minutes, every probe failed, and this log held not one line).
const ATTACH_SWEEP: Duration = Duration::from_secs(5);
/// The node is told to finish this long before the caller's wait ends, so its answer is on the wire
/// before the relay gives up on the connection (sending it is one more round trip).
const ANSWER_MARGIN_MS: u64 = 3_000;
/// The most work one relayed call may be told to do, whatever a caller names.
const MAX_BUDGET_MS: u64 = 300_000;
const MAX_BODY: usize = 4_000_000;

/// One completed result, kept briefly so a retry can still collect it.
struct Stored {
    status: u16,
    body: String,
    at: Instant,
    /// The request's own deadline had passed when this arrived: a real outcome, but not a fresh
    /// answer to the call the caller is retrying, and it must not be presented as one.
    late: bool,
}

#[derive(Default)]
struct RelayState {
    queue: HashMap<String, VecDeque<Value>>,
    waiting: HashMap<String, mpsc::Sender<(u16, String)>>,
    /// When each node last polled. A node that is not attached cannot be
    /// reached, so say so immediately instead of queueing for a minute.
    last_poll: HashMap<String, Instant>,
    /// Whether each node was attached at its last observation, so a transition is logged once
    /// instead of on every poll: the log records attach and detach, not a heartbeat.
    attached: HashMap<String, bool>,
    /// Request ids already queued, so a caller that retries after a timeout
    /// waits on the same request instead of running the action twice.
    issued: HashMap<String, Instant>,
    /// Completed results kept briefly so a retry can still collect them.
    results: HashMap<String, Stored>,
    // Request IDs are scoped to their authenticated sender, recipient and exact envelope.
    owners: HashMap<String, (String, String, String)>,
    /// When the caller of each issued request stops waiting. Stamped by `/relay/send`, carried to the
    /// node as `deadline_ms`, and the number a late answer is judged against.
    deadlines: HashMap<String, u64>,
    next_id: u64,
}

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or(0)
}

fn now_ms() -> u64 { node::now_ms() }

fn iso8601(ms: u64) -> String { node::iso8601(ms) }

fn is_attached(state: &RelayState, node_id: &str) -> bool {
    state.last_poll.get(node_id).map(|at| at.elapsed() < ATTACH_WINDOW).unwrap_or(false)
}

/// A poll from a node whose binding is no longer accepted is a detach with a reason, not silence:
/// the node is reachable but may not be served, and the line says which of the two it is.
fn refuse_poll(relay: &Arc<Mutex<RelayState>>, stream: &mut TcpStream, node_id: &str) -> std::io::Result<()> {
    let line = {
        let mut state = relay.lock().unwrap();
        observe_detached(&mut state, node_id, "binding_not_accepted")
    };
    if let Some(line) = line { eprintln!("{line}"); }
    respond(stream, 403, "{\"error\":\"binding_not_accepted\"}")
}

fn attach_line(action: &str, node_id: &str, reason: &str) -> String {
    format!("[relay] {action} node={node_id} at={} reason={reason}", iso8601(now_ms()))
}

/// The bound a relayed call is given, from what its caller was told.
///
/// The caller holds one connection for `hold`; the node is told to finish `ANSWER_MARGIN_MS` earlier
/// so its answer is delivered before the relay stops waiting. A caller may name a shorter timeout
/// (it knows what it is willing to wait for); it can never lengthen the wait, because the connection
/// is the caller's own bound. One second is the floor: a request handed over with no time left is
/// work the node cannot start, and answering it immediately is the honest outcome.
fn budget_ms(named: Option<u64>, hold: Duration) -> u64 {
    let hold_ms = hold.as_millis() as u64;
    named
        .filter(|ms| (1..=MAX_BUDGET_MS).contains(ms))
        .unwrap_or(hold_ms)
        .min(hold_ms)
        .saturating_sub(ANSWER_MARGIN_MS)
        .max(1_000)
}

/// Record that `node_id` is polling right now, and name the attach if that is a transition.
///
/// Attaching is the moment a caller can reach the node again, so it is worth one line: it is the
/// only evidence that separates "the node came back" from "it never left".
fn observe_poll(state: &mut RelayState, node_id: &str) -> Option<String> {
    let gap = state.last_poll.get(node_id).map(|at| at.elapsed());
    state.last_poll.insert(node_id.to_string(), Instant::now());
    let was = state.attached.insert(node_id.to_string(), true).unwrap_or(false);
    if was {
        return None;
    }
    Some(attach_line(
        "attach",
        node_id,
        &match gap {
            Some(gap) => format!("poll after {:.1}s away", gap.as_secs_f64()),
            None => "first poll".to_string(),
        },
    ))
}

/// Record that `node_id` is not attached right now, and name the detach if that is a transition.
///
/// A slow call and a dropped node look identical to a caller (`node_not_attached` both ways); the
/// reason here is what tells them apart afterwards. With polling split from execution a slow call
/// keeps polling, so a detach means the node really stopped - and a node that only answered late is
/// logged as `slow`, never as a detach.
fn observe_detached(state: &mut RelayState, node_id: &str, reason: &str) -> Option<String> {
    if state.attached.get(node_id).copied() != Some(true) {
        return None;
    }
    state.attached.insert(node_id.to_string(), false);
    Some(attach_line("detach", node_id, reason))
}

/// Log a detach for every node whose window has passed. Called on a timer by `run` and by
/// `/relay/status`, so a node that stops polling is reported even when nobody is calling it.
fn sweep(state: &mut RelayState) -> Vec<String> {
    let stale: Vec<String> = state
        .last_poll
        .iter()
        .filter(|(id, at)| at.elapsed() >= ATTACH_WINDOW && state.attached.get(*id).copied() == Some(true))
        .map(|(id, _)| id.clone())
        .collect();
    stale
        .into_iter()
        .filter_map(|id| {
            let idle = state.last_poll.get(&id).map(|at| at.elapsed().as_secs_f64()).unwrap_or(0.0);
            observe_detached(
                &mut *state,
                &id,
                &format!("no poll for {idle:.1}s (window {:.0}s)", ATTACH_WINDOW.as_secs_f64()),
            )
        })
        .collect()
}

pub fn run(bind: &str, port: u16, db_path: &str) {
    // Schema first, on a short-lived connection. The registry is a store like any other: one busy
    // timeout, WAL, `synchronous=FULL` (`rust/wa-sqlite`).
    match wa_sqlite::open(db_path) {
        Ok(connection) => {
            if let Err(error) = connection.execute_batch(
                "CREATE TABLE IF NOT EXISTS nodes (
                   node_id TEXT PRIMARY KEY,
                   public_key TEXT NOT NULL,
                   name TEXT,
                   role TEXT,
                   endpoints TEXT,
                   last_seen INTEGER,
                   registered_at INTEGER
                 );
                 CREATE TABLE IF NOT EXISTS network_roles (
                   node_id TEXT PRIMARY KEY, role TEXT NOT NULL, changed_by TEXT, changed_at INTEGER
                 );
                 CREATE TABLE IF NOT EXISTS role_requests (
                   signature TEXT PRIMARY KEY, at INTEGER
                 );
                 -- Operators an administrator added at runtime (`POST /operators`), signed by a key
                 -- that was an operator when it asked. The environment list stays the root of trust and
                 -- is never overridden by this table: these rows only ever ADD.
                 CREATE TABLE IF NOT EXISTS network_operators (
                   node_id TEXT PRIMARY KEY, added_by TEXT, added_at INTEGER
                 );
                 -- Environment operators an administrator RETIRED (`POST /operators` with `remove` and
                 -- `retire: true`, operator 17/11): a legacy node whose key is gone can leave the admin set
                 -- without a hand edit of the unit file. Never the last environment operator, never the
                 -- caller itself; vouching for the id again (`add`) lifts it.
                 CREATE TABLE IF NOT EXISTS retired_operators (
                   node_id TEXT PRIMARY KEY, retired_by TEXT, retired_at INTEGER
                 );",
            ) {
                eprintln!("[rendezvous] schema: {error}");
                return;
            }
            if let Err(error)=bindings::schema(&connection){eprintln!("[rendezvous] binding schema: {error}");return;}
            load_runtime_operators(&connection);
            // SQLite has no `ADD COLUMN IF NOT EXISTS`. Existing registries need this once;
            // subsequent starts harmlessly report the duplicate column and continue.
            let _ = connection.execute("ALTER TABLE nodes ADD COLUMN resources TEXT", []);
            // A retirement carries its own proof (the second administrator's signature), so two columns
            // are added to a registry created before them: an older row has neither and is therefore NOT
            // applied - a database alone never retires an environment operator, which is why a retrieved
            // row is verified again on every start (stored_retirement_holds).
            for column in ["approver TEXT", "approval TEXT"] {
                let _ = connection.execute(&format!("ALTER TABLE retired_operators ADD COLUMN {column}"), []);
            }
            if !network_admins().is_empty() {
                if let Err(error) = connection.execute_batch(
                    "UPDATE nodes SET role=COALESCE((SELECT role FROM network_roles WHERE network_roles.node_id=nodes.node_id),'guest');"
                ) { eprintln!("[rendezvous] roles: {error}"); return; }
                for id in network_admins() {
                    if let Err(error) = connection.execute("UPDATE nodes SET role='master' WHERE node_id=?1", [&id]) {
                        eprintln!("[rendezvous] admin: {error}"); return;
                    }
                }
            }
        }
        Err(error) => {
            eprintln!("[rendezvous] open {db_path}: {error}");
            return;
        }
    }

    if let Ok(connection) = wa_sqlite::open(db_path) { prune(&connection); }

    let listener = match TcpListener::bind((bind, port)) {
        Ok(listener) => listener,
        Err(error) => {
            eprintln!("[rendezvous] bind {bind}:{port}: {error}");
            return;
        }
    };
    eprintln!("[rendezvous] listening on {bind}:{port} (db {db_path})");
    if network_admins().is_empty() {
        eprintln!("[rendezvous] WASM_AGENT_NETWORK_ADMINS is empty: every node registers as guest and no peer can command another");
    }

    let relay: Arc<Mutex<RelayState>> = Arc::new(Mutex::new(RelayState::default()));
    // A detach is a silent state change: the node stopped, the link died. Nothing else would report
    // it, so the registry looks for one on a timer instead of only when a caller happens to ask.
    {
        let relay = relay.clone();
        std::thread::spawn(move || loop {
            std::thread::sleep(ATTACH_SWEEP);
            let lines = {
                let mut state = relay.lock().unwrap();
                sweep(&mut state)
            };
            for line in lines {
                eprintln!("{line}");
            }
        });
    }
    // One thread per connection: long polls must not block the registry. Bounded, because this listener
    // is public behind Caddy: an unbounded thread (and SQLite connection) per socket is a way to exhaust
    // the host. Each relay long poll holds one, so the cap leaves room for many nodes.
    let cap = max_connections();
    // The peak open count, for a test (or an operator) that needs the number rather than a suspicion.
    // Written only when asked, so the production listener does no extra I/O.
    let peak_file = std::env::var("WA_RENDEZVOUS_PEAK_FILE").ok().filter(|p| !p.is_empty());
    for stream in listener.incoming() {
        let Ok(mut stream) = stream else { continue };
        let now_open = OPEN.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
        if let Some(path) = &peak_file {
            static PEAK: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
            let seen = PEAK.fetch_max(now_open, std::sync::atomic::Ordering::SeqCst).max(now_open);
            let _ = std::fs::write(path, format!("{} {}\n", seen, cap));
        }
        if now_open > cap {
            OPEN.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
            // Shed with a hint. The old body was a bare 503, which every caller retried at once -
            // measured 19/11, the cap stayed full for half an hour because of exactly that.
            let body = json!({"error":"too_many_connections","retryable":true,
                "retry_after_ms":SHED_RETRY_AFTER_S * 1000,
                "hint":"the registry is at its connection cap; nothing ran, wait and retry"}).to_string();
            let _ = respond_retry(&mut stream, 503, &body, SHED_RETRY_AFTER_S);
            continue;
        }
        // The lane the request belongs to is not known until its head is read, so the reservation is
        // made on the first line - which handle() reads immediately. A request over the non-reserved
        // part of the cap is shed here, before it can take a slot from a poll that needs one.
        let db = db_path.to_string();
        let relay = relay.clone();
        let open_now = OPEN.load(std::sync::atomic::Ordering::SeqCst);
        std::thread::spawn(move || {
            let _ = stream.set_write_timeout(Some(Duration::from_secs(15)));
            if let Err(error) = handle(&db, &mut stream, &relay, open_now, cap) {
                eprintln!("[rendezvous] connection: {error}");
            }
            OPEN.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
        });
    }
}

fn handle(db_path: &str, stream: &mut TcpStream, relay: &Arc<Mutex<RelayState>>, open: usize, cap: usize) -> std::io::Result<()> {
    // One connection per request, so it needs the shared policy or every concurrent registration
    // races the lock with no wait at all (`rust/wa-sqlite`).
    let connection = match wa_sqlite::open(db_path) {
        Ok(connection) => connection,
        Err(error) => {
            return respond(stream, 500, &json!({"error": error.to_string()}).to_string());
        }
    };

    let deadline = std::time::Instant::now() + Duration::from_secs(15);
    let mut data = Vec::new();
    let mut chunk = [0u8; 16384];
    let (method, target, headers, body) = loop {
        // A total deadline for the request, not only per read, so a trickling client cannot hold a slot.
        let left = deadline.saturating_duration_since(std::time::Instant::now());
        if left.is_zero() {
            return Ok(());
        }
        stream.set_read_timeout(Some(left.min(Duration::from_secs(10))))?;
        let read = stream.read(&mut chunk)?;
        if read == 0 {
            return Ok(());
        }
        data.extend_from_slice(&chunk[..read]);
        if let Some(end) = data.windows(4).position(|w| w == b"\r\n\r\n") {
            let head = String::from_utf8_lossy(&data[..end]).to_string();
            let mut lines = head.lines();
            let mut request = lines.next().unwrap_or("").split_whitespace();
            let method = request.next().unwrap_or("").to_string();
            let target = request.next().unwrap_or("/").to_string();
            let mut length = 0usize;
            let mut headers: Vec<(String, String)> = Vec::new();
            for line in lines {
                let lower = line.to_ascii_lowercase();
                if let Some(value) = lower.strip_prefix("content-length:") {
                    length = value.trim().parse().unwrap_or(0);
                } else if let Some((key, value)) = lower.split_once(':') {
                    headers.push((key.trim().to_string(), value.trim().to_string()));
                }
            }
            if length > MAX_BODY || end > 65536 {
                return respond(stream, 413, "{\"error\":\"request_too_large\"}");
            }
            if data.len() >= end + 4 + length {
                break (method, target, headers, data[end + 4..end + 4 + length].to_vec());
            }
        }
        if data.len() > MAX_BODY {
            return Ok(());
        }
    };

    let (path, query) = match target.split_once('?') {
        Some((path, query)) => (path.to_string(), query.to_string()),
        None => (target.clone(), String::new()),
    };
    // The lane is known now, so the reservation can be applied to it. Under load a relayed call is
    // shed before it takes a connection a poll or a binding check would have used (RESERVED_LANES).
    //
    // The count is read HERE, not carried from accept: a long poll occupies its slot for up to 25 s,
    // so the number at accept time is stale by the time the lane is known, and a decision made on a
    // stale count lets a burst of ordinary requests through the reservation exactly when it matters.
    // `open` is kept as the caller's view for the log line only.
    let live = OPEN.load(std::sync::atomic::Ordering::SeqCst);
    let _ = open;
    if shed_for_lane_at(live, is_priority_lane(&path), cap) {
        let body = json!({"error":"too_many_connections","retryable":true,
            "retry_after_ms":SHED_RETRY_AFTER_S * 1000,
            "hint":"the registry is serving its reserved lanes first; nothing ran, wait and retry"}).to_string();
        return respond_retry(stream, 503, &body, SHED_RETRY_AFTER_S);
    }
    let payload: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
    let header = |name: &str| {
        headers
            .iter()
            .find(|(key, _)| key == name)
            .map(|(_, value)| value.clone())
            .unwrap_or_default()
    };

    if path == "/health" {
        return respond(stream, 200, "{\"ok\":true}");
    }
    if path == "/" {
        return respond(stream, 200, &banner(&connection, relay));
    }

    if path == "/service" {
        let admins = network_admins();
        let operators: Vec<Value> = admins.iter().filter_map(|id| lookup(&connection, id)).map(|n|
            json!({"node_id": n["node_id"], "public_key": n["public_key"], "name": n["name"]})
        ).collect();
        // `binding_lifetimes` is the discovery half of the no-expiry branch: a node asks for
        // `permanent` only when this service says it understands it, so an older registry refuses the
        // intent locally with a named reason instead of a raw 400 after local consent is stored.
        return respond(stream, 200, &json!({"protocol": 1, "binding_protocol":1,
            "binding_lifetimes":["standard","permanent"],
            "enrollment_ready": !admins.is_empty() && operators.len() == admins.len(),
            "operators": operators}).to_string());
    }
    if path.starts_with("/bindings/") {
        return bindings::route(&connection,stream,&path,&method,&query,&body,&header);
    }
    if path == "/operators" && method == "POST" {
        // An administrator vouches for one more operator, at runtime, over the wire: signed, audited by
        // the registry's own log, and additive only. This is the door that used to be a hand edit of
        // `WASM_AGENT_NETWORK_ADMINS` on the always-on node — the file a node-side hook refuses to an
        // agent, and the reason a new device could be bound but never allowed to drive anything.
        let from = header("x-wa-node");
        let admins = network_admins();
        if admins.is_empty() {
            return respond(stream, 403, "{\"error\":\"managed_service_required\"}");
        }
        if !verify(&connection, &from, "operators", &header, Some(&body), stream) {
            return Ok(());
        }
        if !admins.contains(&from) {
            return respond(stream, 403, "{\"error\":\"administrator_required\"}");
        }
        let add = payload["add"].as_str().unwrap_or_default();
        let remove = payload["remove"].as_str().unwrap_or_default();
        if add.is_empty() && remove.is_empty() {
            return respond(stream, 400, "{\"error\":\"add_or_remove_required\"}");
        }
        if !add.is_empty() {
            if add.len() != 32 || !add.chars().all(|c| c.is_ascii_hexdigit()) {
                return respond(stream, 400, "{\"error\":\"node_id_invalid\"}");
            }
            if lookup(&connection, add).is_none() {
                // An operator must be a node this registry knows: the key is the identity, and a
                // registration that never happened has no key to vouch for.
                return respond(stream, 404, "{\"error\":\"unknown_node\"}");
            }
            let _ = connection.execute(
                "INSERT INTO network_operators VALUES(?1,?2,?3) ON CONFLICT(node_id) DO NOTHING",
                rusqlite::params![add, from, now()],
            );
            if let Ok(mut extra) = EXTRA_OPERATORS.lock() {
                if !extra.iter().any(|id| id == add) {
                    extra.push(add.to_string());
                }
            }
            let _ = connection.execute("DELETE FROM retired_operators WHERE node_id = ?1", rusqlite::params![add]);
            if let Ok(mut retired) = RETIRED_OPERATORS.lock() { retired.retain(|id| id != add); }
            eprintln!("[rendezvous] operator {} added by administrator {}", &add[..add.len().min(12)], &from[..from.len().min(12)]);
        }
        if !remove.is_empty() {
            let outcome = connection.execute(
                "DELETE FROM network_operators WHERE node_id = ?1",
                rusqlite::params![remove],
            );
            if let Ok(mut extra) = EXTRA_OPERATORS.lock() {
                extra.retain(|id| id != remove);
            }
            if matches!(outcome, Ok(0)) {
                // An operator named by the environment is RETIRED, not deleted, and only when asked in
                // so many words (retire: true): the unit file stays the root of trust, this row
                // subtracts.
                let environment = env_operators();
                let refuse = |stream: &mut TcpStream, status: u16, error: &str| {
                    respond(stream, status, &json!({"error": error}).to_string())
                };
                if !environment.iter().any(|id| id == remove) {
                    return refuse(stream, 404, "not_an_operator");
                }
                if !payload["retire"].as_bool().unwrap_or(false) {
                    return refuse(stream, 409, "operator_from_environment");
                }
                if remove == from {
                    return refuse(stream, 409, "operator_cannot_retire_itself");
                }
                // A retirement is TWO administrators' decision, not one signature's: the caller signs
                // the request and a different administrator signs this exact retirement
                // (approval_problem). The roster's revocation gate lives on the node that asks; this is
                // the gate the registry can enforce itself, for every caller.
                let nonce = payload["nonce"].as_str().unwrap_or_default();
                if nonce.is_empty() {
                    return refuse(stream, 400, "nonce_required");
                }
                let admins = network_admins();
                if let Err(problem) = approval_problem(&connection, &admins, &environment, &payload, remove, &from, nonce) {
                    return refuse(stream, 409, problem);
                }
                let retired_now: Vec<String> = RETIRED_OPERATORS.lock().map(|list| list.clone()).unwrap_or_default();
                if let Some(problem) = last_operator_problem(&environment, &retired_now, remove, &from) {
                    return refuse(stream, 409, problem);
                }
                let approval = &payload["approval"];
                let approver = approval["node_id"].as_str().unwrap_or_default().to_string();
                // The row keeps everything needed to check itself again after a restart: who asked,
                // who approved, and the signature over the message those two make together.
                let kept = json!({
                    "node_id": approver, "ts": approval["ts"].clone(),
                    "signature": approval["signature"].clone(), "caller": from, "nonce": nonce,
                });
                let _ = connection.execute(
                    "INSERT INTO retired_operators(node_id,retired_by,retired_at,approver,approval)
                     VALUES(?1,?2,?3,?4,?5)
                     ON CONFLICT(node_id) DO UPDATE SET retired_by=excluded.retired_by,
                       retired_at=excluded.retired_at, approver=excluded.approver, approval=excluded.approval",
                    rusqlite::params![remove, from, now(), approver, kept.to_string()],
                );
                if let Ok(mut retired) = RETIRED_OPERATORS.lock() {
                    if !retired.iter().any(|id| id == remove) { retired.push(remove.to_string()); }
                }
                eprintln!("[rendezvous] environment operator {} retired by administrator {}, approved by {}",
                    &remove[..remove.len().min(12)], &from[..from.len().min(12)], &approver[..approver.len().min(12)]);
            }
            eprintln!("[rendezvous] operator {} removed", &remove[..remove.len().min(12)]);
        }
        let operators = network_admins();
        return respond(stream, 200, &json!({"ok": true, "operators": operators}).to_string());
    }
    if path == "/role" && method == "POST" {
        return grant_role(&connection, stream, &payload, &body, &header);
    }

    // ---- registry --------------------------------------------------------
    if (path == "/register" || path == "/heartbeat") && method == "POST" {
        return register(&connection, stream, &payload, &path);
    }
    if path == "/forget" && method == "POST" {
        return forget(&connection, stream, &payload, &body, &header);
    }
    if path == "/lookup" {
        let node_id = query_value(&query, "node_id");
        let admins = network_admins();
        if !admins.is_empty() && !admins.contains(&node_id) {
            let from = header("x-wa-node");
            if !verify(&connection, &from, "lookup", &header, None, stream) { return Ok(()); }
            if from != node_id && !is_master(&connection, &from) {
                return respond(stream, 403, "{\"error\":\"forbidden_role\"}");
            }
        }
        return match lookup(&connection, &node_id) {
            Some(mut node) => {
                node["binding"] = bindings::current(&connection,&node_id);
                node["relay_attached"] = json!(is_attached(&relay.lock().unwrap(), &node_id));
                respond(stream, 200, &node.to_string())
            }
            None => respond(stream, 404, "{\"error\":\"unknown_node\"}"),
        };
    }
    if path == "/nodes" {
        if !network_admins().is_empty() {
            let from = header("x-wa-node");
            if !verify(&connection, &from, "nodes", &header, None, stream) { return Ok(()); }
            if !is_master(&connection, &from) { return respond(stream, 403, "{\"error\":\"forbidden_role\"}"); }
        }
        return respond(stream, 200, &list(&connection).to_string());
    }

    // ---- relay -----------------------------------------------------------
    if path == "/relay/poll" {
        let node_id = query_value(&query, "node_id");
        if !verify(&connection, &node_id, "relay-poll", &header, None, stream) {
            return Ok(());
        }
        if !bindings::permits(&connection,&node_id){return refuse_poll(relay,stream,&node_id);}
        let deadline = Instant::now() + POLL_WAIT;
        loop {
            if !bindings::permits(&connection,&node_id){return refuse_poll(relay,stream,&node_id);}
            let mut lines: Vec<String> = Vec::new();
            let next = {
                let mut state = relay.lock().unwrap();
                // Every iteration of the long poll is this node polling: refresh the stamp and log
                // the attach if this is the moment it came back.
                if let Some(line) = observe_poll(&mut state, &node_id) { lines.push(line); }
                // Hand out the next request that still has time on it. One whose caller has already
                // stopped waiting is dropped here, never run: the node must not start work whose
                // answer nobody can collect (docs/RENDEZVOUS.md, "abandoned work is dropped").
                let queued = state.queue.remove(&node_id).unwrap_or_default();
                let now = now_ms();
                let mut taken = None;
                let mut rest = VecDeque::new();
                for request in queued {
                    let id = request["id"].as_str().unwrap_or_default().to_string();
                    if state.deadlines.get(&id).map(|at| now > *at).unwrap_or(false) {
                        state.issued.remove(&id);
                        state.owners.remove(&id);
                        state.deadlines.remove(&id);
                        lines.push(format!("[relay] abandon node={node_id} at={} rid={id} reason=deadline_passed", iso8601(now)));
                        continue;
                    }
                    if taken.is_none() { taken = Some(request); } else { rest.push_back(request); }
                }
                state.queue.insert(node_id.clone(), rest);
                taken
            };
            for line in lines { eprintln!("{line}"); }
            if let Some(request) = next {
                return respond(stream, 200, &json!({"request": request}).to_string());
            }
            if Instant::now() >= deadline {
                return respond(stream, 200, "{}");
            }
            std::thread::sleep(Duration::from_millis(120));
        }
    }
    if path == "/relay/respond" && method == "POST" {
        let node_id = payload["node_id"].as_str().unwrap_or_default().to_string();
        if !verify(&connection, &node_id, "relay-respond", &header, None, stream) {
            return Ok(());
        }
        let id = payload["id"].as_str().unwrap_or_default().to_string();
        let status = payload["status"].as_u64().unwrap_or(200) as u16;
        let body = payload["body"].as_str().unwrap_or_default().to_string();
        let answer: Value = serde_json::from_str(&body).unwrap_or(Value::Null);
        // A refusal the node made before starting any work (its relay lane was full). It is not an
        // outcome under this rid: the request is erased so the caller's retry, with the same rid, can
        // actually run - at-most-once still holds because nothing ran.
        let not_started = status == 503 && answer["not_started"] == json!(true);
        let mut line = None;
        {
            let mut state = relay.lock().unwrap();
            if !state.owners.get(&id).map(|owner| owner.1 == node_id).unwrap_or(false) {
                return respond(stream, 403, "{\"error\":\"not_request_recipient\"}");
            }
            if state.results.contains_key(&id) { return respond(stream, 409, "{\"error\":\"already_completed\"}"); }
            let deadline = state.deadlines.remove(&id);
            let late = deadline.map(|at| now_ms() > at).unwrap_or(false);
            if not_started {
                state.issued.remove(&id);
                state.owners.remove(&id);
                if let Some(queue) = state.queue.get_mut(&node_id) {
                    queue.retain(|request| request["id"].as_str() != Some(id.as_str()));
                }
                line = Some(format!("[relay] busy node={node_id} at={} rid={id} reason={}",
                    iso8601(now_ms()), answer["error"].as_str().unwrap_or("busy")));
            } else {
                state.issued.remove(&id);
                if late {
                    // Say it, and keep saying it: a late result is collected by a retry, so the label
                    // travels with it (`/relay/send` `late:true`) instead of the answer looking fresh.
                    line = Some(format!("[relay] late node={node_id} at={} rid={id} reason=answered after the caller's deadline", iso8601(now_ms())));
                }
                // Keep the result briefly even if nobody is waiting right now,
                // so a caller that timed out can still collect it.
                state.results.insert(id.clone(), Stored { status, body: body.clone(), at: Instant::now(), late });
            }
            if let Some(sender) = state.waiting.remove(&id) {
                let _ = sender.send((status, body));
            }
        }
        if let Some(line) = line { eprintln!("{line}"); }
        respond(stream, 200, "{\"ok\":true}")
    } else if path == "/relay/send" && method == "POST" {
        let from = header("x-wa-node");
        if !verify(&connection, &from, "relay-send", &header, None, stream) {
            return Ok(());
        }
        let caller = lookup(&connection, &from);
        let is_master = caller
            .as_ref()
            .and_then(|node| node["role"].as_str())
            .map(|role| role == "master" || role == "admin")
            .unwrap_or(false);
        if !is_master {
            return respond(stream, 403, "{\"error\":\"forbidden_role\"}");
        }
        let to = payload["to"].as_str().unwrap_or_default().to_string();
        if !bindings::permits(&connection,&from)||!bindings::permits(&connection,&to){return respond(stream,403,"{\"error\":\"binding_not_accepted\"}");}
        if to.is_empty() {
            return respond(stream, 400, "{\"error\":\"to_required\"}");
        }
        if lookup(&connection, &to).is_none() {
            return respond(stream, 404, "{\"error\":\"unknown_node\"}");
        }
        let id = payload["rid"].as_str().filter(|value| !value.is_empty()).map(str::to_string);
        let id = id.unwrap_or_else(|| {
            let mut state = relay.lock().unwrap();
            state.next_id += 1;
            format!("r{}", state.next_id)
        });
        let (tx, rx) = mpsc::channel();
        let mut lines: Vec<String> = Vec::new();
        let (hold, deadline_ms) = {
            let mut state = relay.lock().unwrap();
            // Fair shedding BEFORE anything is queued: a caller at its per-caller limit, or a target
            // whose queue is already longer than it can drain. One caller cannot fill the registry
            // for everyone, and a node that is behind is not given still more work to abandon.
            // Calls this caller has issued and whose answer it is still waiting for: the ones that
            // actually hold the registry, counted from the ids in flight, not from a global total.
            let caller_in_flight = state.waiting.keys()
                .filter(|rid| state.owners.get(*rid).map(|owner| owner.0 == from).unwrap_or(false))
                .count();
            let queued_for_target = state.queue.get(&to).map(|q| q.len()).unwrap_or(0);
            if let Some(reason) = lane_refusal(caller_in_flight, queued_for_target) {
                let body = json!({"error":reason,"to":to,"rid":id,"retryable":true,
                    "retry_after_ms":SHED_RETRY_AFTER_S * 1000,
                    "hint":"nothing was queued; the same rid may be sent again after the wait"}).to_string();
                drop(state);
                return respond_retry(stream, 503, &body, SHED_RETRY_AFTER_S);
            }
            state.results.retain(|_, stored| stored.at.elapsed() < Duration::from_secs(120));
            state.issued.retain(|_, at| at.elapsed() < Duration::from_secs(120));
            let live: std::collections::HashSet<String> = state.issued.keys().chain(state.results.keys()).cloned().collect();
            state.owners.retain(|id, _| live.contains(id));
            state.deadlines.retain(|id, _| live.contains(id));
            for queue in state.queue.values_mut() { queue.retain(|r| r["id"].as_str().map(|id| live.contains(id)).unwrap_or(false)); }
            let owner = (from.clone(), to.clone(), body_hash(&body));
            if state.owners.get(&id).map(|old| old != &owner).unwrap_or(false) {
                return respond(stream, 409, "{\"error\":\"request_id_conflict\"}");
            }
            if let Some(stored) = state.results.get(&id) {
                // A retry collects the same result - and an answer the node produced after the
                // deadline its caller was given says so, instead of looking like a fresh one.
                return respond(stream, 200, &json!({"ok":true,"status":stored.status,"body":stored.body,
                    "replayed":true,"late":stored.late,"expired":stored.late}).to_string());
            }
            if state.waiting.contains_key(&id) {
                return respond(stream, 409, "{\"error\":\"request_in_flight\"}");
            }
            state.waiting.insert(id.clone(), tx);
            // A node whose window just passed is logged here as detached: this is the moment a caller
            // finds out, and the reason has to be in the log before the 504 is sent.
            lines.extend(sweep(&mut state));
            let attached = is_attached(&state, &to);
            let hold = if attached { SEND_WAIT } else { ATTACH_HOLD };
            let named = payload["timeout_ms"].as_u64().filter(|ms| (1..=MAX_BUDGET_MS).contains(ms));
            let budget_ms = budget_ms(named, hold);
            let deadline_ms = now_ms() + budget_ms;
            if !state.issued.contains_key(&id) {
                state.owners.insert(id.clone(), owner);
                state.issued.insert(id.clone(), Instant::now());
                state.deadlines.insert(id.clone(), deadline_ms);
                state.queue.entry(to.clone()).or_default().push_back(json!({
                    "id":id,"from":from,"method":payload["method"].as_str().unwrap_or("POST"),
                    "path":payload["path"].as_str().unwrap_or("/"),"headers":payload["headers"].clone(),
                    "body":payload["body"].as_str().unwrap_or(""),
                    // The node's own bound, absolute so it cannot drift from the relay's judgement of
                    // a late answer, and the reason it has that number.
                    "budget_ms":budget_ms,"deadline_ms":deadline_ms,
                    "timeout_source":if named.is_some(){"caller"}else{"relay"}
                }));
            }
            (hold, deadline_ms)
        };
        for line in lines { eprintln!("{line}"); }
        match rx.recv_timeout(hold) {
            Ok((status, body)) => {
                relay.lock().unwrap().waiting.remove(&id);
                // The node declined before starting any work (its relayed-call lane was full). That
                // is not an outcome under this rid: nothing ran, so the caller may send the same rid
                // again and the relay hands it over.
                if status == 503 && serde_json::from_str::<Value>(&body).map(|v| v["not_started"] == json!(true)).unwrap_or(false) {
                    return respond(stream, 503, &json!({"error":"node_busy","rid":id,"to":to,
                        "retryable":true,"retry_after_ms":750,
                        "hint":"the node is at its relayed-call limit; nothing ran, so the same rid may be sent again"}).to_string());
                }
                respond(stream, 200, &json!({"ok": true, "status": status, "body": body,
                    "late": now_ms() > deadline_ms}).to_string())
            }
            Err(_) => {
                // Two different situations, and the caller needs to tell them
                // apart: a node that never attached (retry when it is back) and a
                // node that is attached but did not answer in time (it is busy -
                // the action may still be running, so do not repeat it blindly).
                let attached_now = is_attached(&relay.lock().unwrap(), &to);
                relay.lock().unwrap().waiting.remove(&id);
                // The one line that separates a slow call from a drop after the fact.
                eprintln!("[relay] {} node={to} at={} rid={id} reason={} waited_ms={}",
                    if attached_now { "slow" } else { "unreachable" }, iso8601(now_ms()),
                    if attached_now { "attached but no answer within the caller's wait" }
                    else { "not attached when the caller asked" },
                    hold.as_millis() as u64);
                respond(
                    stream,
                    504,
                    &json!({
                        "error": if attached_now { "node_no_answer" } else { "node_not_attached" },
                        "rid": id,
                        "to": to,
                        "waited_ms": hold.as_millis() as u64,
                        "deadline_ms": deadline_ms,
                        "retryable": true,
                        "retry_after_ms": 750,
                        "hint": if attached_now {
                            "the node is attached but did not answer in time; it may still be working"
                        } else {
                            "the node is not attached right now; it re-attaches on its next poll"
                        },
                    })
                    .to_string(),
                )
            }
        }
    } else if path == "/relay/status" {
        if !network_admins().is_empty() {
            let from = header("x-wa-node");
            if !verify(&connection, &from, "relay-status", &header, None, stream) { return Ok(()); }
            if !is_master(&connection, &from) { return respond(stream, 403, "{\"error\":\"forbidden_role\"}"); }
        }
        let mut lines: Vec<String> = Vec::new();
        let (queue, waiting, attached) = {
            let mut state = relay.lock().unwrap();
            // A status read is also an observation: a node that stopped polling is named here, so
            // the operator reading `/relay/status` learns why the next call will fail.
            lines.extend(sweep(&mut state));
            let queue: Vec<Value> = state
                .queue
                .iter()
                .filter(|(_, entries)| !entries.is_empty())
                .map(|(node, entries)| json!({"node_id": node, "queued": entries.len()}))
                .collect();
            let attached: Vec<Value> = state
                .last_poll
                .keys()
                .filter(|node| is_attached(&state, node))
                .map(|node| json!(node))
                .collect();
            (queue, state.waiting.len(), attached)
        };
        for line in lines { eprintln!("{line}"); }
        respond(
            stream,
            200,
            &json!({"ok": true, "queued": queue, "waiting": waiting, "attached": attached})
                .to_string(),
        )
    } else {
        respond(stream, 404, "{\"error\":\"not_found\"}")
    }
}

fn banner(connection: &Connection, relay: &Arc<Mutex<RelayState>>) -> String {
    let total: i64 = connection
        .query_row("SELECT COUNT(*) FROM nodes", [], |row| row.get(0))
        .unwrap_or(0);
    let online: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM nodes WHERE last_seen > ?1",
            rusqlite::params![now() - ONLINE_WINDOW],
            |row| row.get(0),
        )
        .unwrap_or(0);
    let state = relay.lock().unwrap();
    let queued: usize = state.queue.values().map(|entries| entries.len()).sum();
    json!({
        "service": "wasm-agent rendezvous + relay",
        "protocol": "nodes bind by ed25519 key, not address",
        "nodes": total,
        "online": online,
        "relay": { "queued": queued, "waiting": state.waiting.len() },
        "endpoints": [
            "POST /register", "POST /heartbeat", "POST /forget",
            "GET /lookup?node_id=", "GET /nodes", "GET /health",
            "GET /relay/poll?node_id=", "POST /relay/respond", "POST /relay/send",
            "GET /relay/status"
        ]
    })
    .to_string()
}

fn retention() -> i64 {
    std::env::var("WA_RENDEZVOUS_RETENTION_SECONDS").ok()
        .and_then(|value| value.trim().parse::<i64>().ok())
        .filter(|value| *value >= 0)
        .unwrap_or(DEFAULT_RETENTION)
}

/// Delete registrations unseen for longer than the retention window (never an admin). Returns the count.
fn prune(connection: &Connection) -> usize {
    let window = retention();
    if window == 0 { return 0; }
    let admins = network_admins();
    let cutoff = now() - window;
    let stale: Vec<String> = connection
        .prepare("SELECT node_id FROM nodes WHERE last_seen IS NULL OR last_seen < ?1")
        .and_then(|mut statement| {
            let rows = statement.query_map([cutoff], |row| row.get::<_, String>(0))?;
            Ok(rows.flatten().collect())
        })
        .unwrap_or_default();
    let mut removed = 0;
    for id in stale.iter().filter(|id| !admins.contains(id)) {
        if connection.execute("DELETE FROM nodes WHERE node_id = ?1", [id]).unwrap_or(0) > 0 { removed += 1; }
    }
    if removed > 0 { eprintln!("[rendezvous] pruned {removed} registration(s) unseen for {window}s"); }
    removed
}

fn network_admins() -> Vec<String> {
    let mut list: Vec<String> = std::env::var("WASM_AGENT_NETWORK_ADMINS")
        .unwrap_or_default()
        .split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .collect();
    // Retired environment operators leave the list (never all of them: `POST /operators` refuses the last).
    if let Ok(retired) = RETIRED_OPERATORS.lock() {
        let before = list.clone();
        list.retain(|id| !retired.contains(id));
        if list.is_empty() { list = before; } // a database that retired everyone is ignored, not obeyed
    }
    // Operators added at runtime (`POST /operators`). The environment list is the root of trust: a row
    // here can only add, never remove, so a leaked database cannot lock the operator out of his own
    // registry. Read through a cache the endpoint keeps current.
    if let Ok(extra) = EXTRA_OPERATORS.lock() {
        for id in extra.iter() {
            if !list.contains(id) {
                list.push(id.clone());
            }
        }
    }
    list
}

/// The operator rows this registry loaded at start, plus every one an administrator added since.
/// Process-wide on purpose: `network_admins()` is asked by nine call sites that carry no connection.
static EXTRA_OPERATORS: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());
/// Environment operators an administrator retired (`retired_operators`).
static RETIRED_OPERATORS: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());

fn env_operators() -> Vec<String> {
    std::env::var("WASM_AGENT_NETWORK_ADMINS").unwrap_or_default().split(',').map(str::trim)
        .filter(|s| !s.is_empty()).map(str::to_string).collect()
}

/// The administrators' public keys as the ENVIRONMENT names them: `WASM_AGENT_NETWORK_ADMIN_KEYS`, a
/// comma-separated list of `node_id=public_key` pairs. A stored retirement is verified against these and
/// not against the registry's own `nodes` table (which is what `public_key_of` reads): the stored row and
/// the key that approves it used to come from the same database, so anyone able to write the database
/// could retire an environment operator by putting their own key under an administrator's id. The
/// environment is the root of trust for the operator list; it is the root of trust for their keys too.
///
/// A node whose keys are not here keeps every stored retirement unapplied - the safe direction, because
/// the whole point of the proof is that a row alone retires nobody.
fn env_admin_keys() -> Vec<(String, String)> {
    std::env::var("WASM_AGENT_NETWORK_ADMIN_KEYS").unwrap_or_default()
        .split(',').filter_map(|pair| {
            let (id, key) = pair.split_once('=')?;
            let (id, key) = (id.trim(), key.trim());
            if id.is_empty() || key.is_empty() { return None; }
            Some((id.to_string(), key.to_lowercase()))
        }).collect()
}

/// The message a second administrator signs to approve one retirement. It names the target, the
/// administrator that asked, the request nonce and the approval's own timestamp: an approval cannot be
/// replayed for another target, another caller, or after its window.
fn retirement_message(target: &str, caller: &str, nonce: &str, ts: i64) -> String {
    format!("retire|{target}|{caller}|{nonce}|{ts}")
}

/// How old an approval may be. Two administrators sign at their own prompts, so the window is wider
/// than a request's own 120 s - but a signature is never good forever.
const APPROVAL_WINDOW_SECONDS: i64 = 900;

/// Why a retirement may not happen, or Ok(()).
///
/// Retiring an operator named by the registry's environment needs a SECOND administrator's signature
/// over this exact retirement: one compromised or leaked administrator key cannot empty the fleet's own
/// list of operators, and the roster's revocation gate on the asking node stays what it is. An
/// administrator the registry added at runtime may not retire one either - the environment's list is the
/// root of trust, and only its own members may shorten it.
fn approval_problem(connection: &Connection, admins: &[String], environment: &[String], payload: &Value,
                    target: &str, caller: &str, nonce: &str) -> Result<(), &'static str> {
    let approval = payload.get("approval").ok_or("approval_required")?;
    let approver = approval["node_id"].as_str().unwrap_or_default();
    if approver.is_empty() { return Err("approval_node_required"); }
    if approver == caller { return Err("approval_self"); }
    if approver == target { return Err("approval_target"); }
    if !admins.iter().any(|id| id == approver) { return Err("approval_not_an_administrator"); }
    let ts = approval["ts"].as_i64().unwrap_or(0);
    if (now() - ts).abs() > APPROVAL_WINDOW_SECONDS { return Err("approval_stale"); }
    let signature = approval["signature"].as_str().unwrap_or_default();
    if signature.is_empty() { return Err("approval_signature_required"); }
    let key = public_key_of(connection, approver).ok_or("approval_unknown_node")?;
    if !node::verify(&key, &retirement_message(target, caller, nonce, ts), signature) {
        return Err("approval_bad_signature");
    }
    // An environment operator leaves the fleet's list only while the fleet's own root of trust is
    // speaking: a caller that is NOT one of the environment's operators needs an environment operator's
    // signature, so a key the registry added at runtime (a vouch, never the root of trust) cannot
    // shorten the list. A caller that IS one of them needs any second administrator, because the list is
    // already speaking for itself and the target may be dead (its key gone) and unable to sign.
    let caller_stands = environment.iter().any(|id| id == caller);
    if environment.iter().any(|id| id == target) && !caller_stands
        && !environment.iter().any(|id| id == approver) {
        return Err("approval_environment_operator_required");
    }
    Ok(())
}

/// Would this retirement leave the environment's list empty? The caller counts only when the caller is
/// one of them: an administrator the registry added may never be the last operator standing, which is
/// what "one administrator retires everyone else and keeps the fleet" needs.
fn last_operator_problem(environment: &[String], retired: &[String], target: &str, caller: &str) -> Option<&'static str> {
    let caller_stands = environment.iter().any(|id| id == caller);
    let remaining = environment.iter()
        .filter(|id| *id != target && !retired.contains(id) && (*id != caller || caller_stands))
        .count();
    if remaining == 0 { Some("last_environment_operator") } else { None }
}

/// A stored retirement, and whether its own proof still holds. A row without a verifiable approval is
/// ignored: the database alone retires nothing, so a leaked or edited registry cannot take an
/// environment operator out of the list.
fn stored_retirement_holds(target: &str, retired_by: &str, approver: &str, approval: &str,
                           retired_at: i64, environment: &[String], keys: &[(String, String)]) -> bool {
    if approver.is_empty() || approval.is_empty() { return false; }
    let Ok(value) = serde_json::from_str::<Value>(approval) else { return false };
    if value["node_id"].as_str().unwrap_or_default() != approver { return false; }
    if value["caller"].as_str().unwrap_or_default() != retired_by { return false; }
    let nonce = value["nonce"].as_str().unwrap_or_default();
    let ts = value["ts"].as_i64().unwrap_or(0);
    let signature = value["signature"].as_str().unwrap_or_default();
    if nonce.is_empty() || signature.is_empty() { return false; }
    // Three facts come from the ENVIRONMENT, never from the row's own database (review, 18/11): the
    // approver must be one of the environment's administrators, its public key must be the one the
    // environment names for it, and the approval must be contemporary with the retirement it approved -
    // inside the window `approval_problem` enforces when the retirement is MADE, measured against the
    // row's own `retired_at`. A signature over a stored row otherwise outlives every decision around it.
    if !environment.iter().any(|id| id == approver) { return false; }
    let Some(key) = keys.iter().find(|(id, _)| id == approver).map(|(_, key)| key.as_str()) else { return false };
    if (ts - retired_at).abs() > APPROVAL_WINDOW_SECONDS { return false; }
    node::verify(key, &retirement_message(target, retired_by, nonce, ts), signature)
}

fn load_runtime_operators(connection: &Connection) {
    let rows: Vec<String> = connection
        .prepare("SELECT node_id FROM network_operators")
        .and_then(|mut statement| {
            let rows = statement.query_map([], |row| row.get::<_, String>(0))?;
            Ok(rows.flatten().collect())
        })
        .unwrap_or_default();
    if let Ok(mut extra) = EXTRA_OPERATORS.lock() {
        for id in rows {
            if !extra.contains(&id) {
                extra.push(id);
            }
        }
    }
    // Only a retirement that carries a verifiable second signature is applied. A row without one - a
    // registry edited by hand, or one written before the proof existed - retires nobody.
    // The proof is checked against the ENVIRONMENT's administrators and their keys, so a row's own
    // database cannot vouch for itself (review, 18/11).
    let environment = env_operators();
    let keys = env_admin_keys();
    let retired: Vec<String> = connection
        .prepare("SELECT node_id, retired_by, approver, approval, retired_at FROM retired_operators")
        .and_then(|mut statement| {
            let rows = statement.query_map([], |row| Ok((
                row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?.unwrap_or_default(),
                row.get::<_, Option<String>>(2)?.unwrap_or_default(),
                row.get::<_, Option<String>>(3)?.unwrap_or_default(),
                row.get::<_, Option<i64>>(4)?.unwrap_or_default(),
            )))?;
            let mut kept = Vec::new();
            for row in rows.flatten() { kept.push(row); }
            Ok(kept)
        })
        .unwrap_or_default()
        .into_iter()
        .filter(|(target, retired_by, approver, approval, retired_at)| stored_retirement_holds(
            target, retired_by, approver, approval, *retired_at, &environment, &keys))
        .map(|(target, _, _, _, _)| target)
        .collect();
    if keys.is_empty() {
        // The operator needs to know why a retirement it already recorded is not being applied: a
        // stored approval is verified against the environment's keys and against nothing else.
        let rows: i64 = connection
            .query_row("SELECT COUNT(*) FROM retired_operators", [], |row| row.get(0)).unwrap_or(0);
        if rows > 0 {
            eprintln!("[rendezvous] WASM_AGENT_NETWORK_ADMIN_KEYS is empty: {} stored retirement(s) cannot be verified and are NOT applied", rows);
        }
    }
    if let Ok(mut list) = RETIRED_OPERATORS.lock() { *list = retired; }
}
fn body_hash(bytes: &[u8]) -> String {
    node::hex(ring::digest::digest(&ring::digest::SHA256, bytes).as_ref())
}
fn is_master(connection: &Connection, id: &str) -> bool {
    bindings::permits(connection,id) && lookup(connection, id).map(|n| n["role"] == "master" || n["role"] == "admin").unwrap_or(false)
}
fn grant_role(connection: &Connection, stream: &mut TcpStream, payload: &Value,
              body: &[u8], header: &dyn Fn(&str) -> String) -> std::io::Result<()> {
    let from = header("x-wa-node");
    let admins = network_admins();
    if admins.is_empty() { return respond(stream, 403, "{\"error\":\"managed_service_required\"}"); }
    if !verify(connection, &from, "grant-role", header, Some(body), stream) { return Ok(()); }
    if !admins.contains(&from) { return respond(stream, 403, "{\"error\":\"administrator_required\"}"); }
    let id = payload["node_id"].as_str().unwrap_or("");
    let role = payload["role"].as_str().unwrap_or("");
    if !matches!(role, "master" | "guest") || admins.iter().any(|a| a == id) {
        return respond(stream, 400, "{\"error\":\"invalid_role_target\"}");
    }
    if lookup(connection, id).is_none() { return respond(stream, 404, "{\"error\":\"unknown_node\"}"); }
    if !bindings::permits(connection,id){return respond(stream,403,"{\"error\":\"binding_not_accepted\"}");}
    if let Some(binding)=bindings::current(connection,id).as_object() {
        if payload["binding_id"]!=binding["request"]["id"] || payload["binding_digest"]!=binding["digest"] || payload["binding_revision"]!=binding["revision"] || payload["public_key"]!=binding["request"]["public_key"] || payload["expected_role"]!=lookup(connection,id).unwrap_or(Value::Null)["role"] {
            return respond(stream,409,"{\"error\":\"binding_generation_changed\"}");
        }
    }
    let result = (|| -> rusqlite::Result<()> {
        let tx = connection.unchecked_transaction()?;
        if !bindings::permits(&tx,id){return Err(rusqlite::Error::ExecuteReturnedResults);}
        if let Some(binding)=bindings::current(&tx,id).as_object() {
            if payload["binding_id"]!=binding["request"]["id"]||payload["binding_digest"]!=binding["digest"]||payload["binding_revision"]!=binding["revision"]||payload["public_key"]!=binding["request"]["public_key"]||payload["expected_role"]!=lookup(&tx,id).unwrap_or(Value::Null)["role"] {return Err(rusqlite::Error::ExecuteReturnedResults);}
        }
        tx.execute("DELETE FROM role_requests WHERE at < ?1", [now() - 240])?;
        tx.execute("INSERT INTO role_requests VALUES(?1,?2)", rusqlite::params![header("x-wa-sig"), now()])?;
        tx.execute("INSERT INTO network_roles VALUES(?1,?2,?3,?4) ON CONFLICT(node_id) DO UPDATE SET role=excluded.role,changed_by=excluded.changed_by,changed_at=excluded.changed_at",
            rusqlite::params![id, role, from, now()])?;
        tx.execute("UPDATE nodes SET role=?1 WHERE node_id=?2", rusqlite::params![role, id])?;
        tx.commit()
    })();
    match result {
        Ok(()) => respond(stream, 200, &json!({"ok":true,"node_id":id,"role":role}).to_string()),
        Err(error) => respond(stream, 409, &json!({"error":"role_change_failed","detail":error.to_string()}).to_string()),
    }
}

/// Verify a signed relay call: `action|node_id|ts`.
fn verify(
    connection: &Connection,
    node_id: &str,
    action: &str,
    header: &dyn Fn(&str) -> String,
    body: Option<&[u8]>,
    stream: &mut TcpStream,
) -> bool {
    if node_id.is_empty() {
        let _ = respond(stream, 400, "{\"error\":\"node_id_required\"}");
        return false;
    }
    let public_key = header("x-wa-pub");
    let ts = header("x-wa-ts");
    let signature = header("x-wa-sig");
    let stored = public_key_of(connection, node_id);
    let Some(stored) = stored else {
        let _ = respond(stream, 401, "{\"error\":\"unknown_node\"}");
        return false;
    };
    if stored != public_key {
        let _ = respond(stream, 401, "{\"error\":\"bad_signature_key\"}");
        return false;
    }
    let ts_value: i64 = ts.parse().unwrap_or(0);
    if (now() - ts_value).abs() > 120 {
        let _ = respond(stream, 401, "{\"error\":\"stale_request\"}");
        return false;
    }
    let mut message = format!("{action}|{node_id}|{ts_value}");
    if let Some(body) = body { message.push_str(&format!("|{}", body_hash(body))); }
    if !node::verify(&stored, &message, &signature) {
        eprintln!("[probe] verify_failed action={action} msg_len={} sig_len={}", message.len(), signature.len());
        let _ = respond(stream, 401, "{\"error\":\"bad_signature_sig\"}");
        return false;
    }
    true
}

fn register(connection: &Connection, stream: &mut TcpStream, payload: &Value, path: &str) -> std::io::Result<()> {
    let node_id = payload["node_id"].as_str().unwrap_or_default();
    let public_key = payload["public_key"].as_str().unwrap_or_default();
    let ts = payload["ts"].as_i64().unwrap_or(0);
    let signature = payload["signature"].as_str().unwrap_or_default();
    if node_id.is_empty() || public_key.is_empty() {
        return respond(stream, 400, "{\"error\":\"node_id_and_public_key_required\"}");
    }
    let key = node::unhex(public_key).unwrap_or_default();
    if key.len() != 32 || body_hash(&key)[..32] != *node_id {
        return respond(stream, 401, "{\"error\":\"node_id_key_mismatch\"}");
    }
    if now().abs_diff(ts) > 120 { return respond(stream, 401, "{\"error\":\"stale_request\"}"); }
    if public_key_of(connection, node_id).map(|old| old != public_key).unwrap_or(false) {
        return respond(stream, 409, "{\"error\":\"identity_conflict\"}");
    }
    let signed_name = payload["name"].as_str().unwrap_or_default();
    let signed_endpoints = if payload["endpoints"].is_array() { payload["endpoints"].clone() } else { json!([]) };
    if !node::verify(public_key, &node::announcement(node_id, ts as u64, signed_name, &signed_endpoints), signature) {
        return respond(stream, 401, "{\"error\":\"bad_signature\"}");
    }
    let now = now();
    let name = payload["name"].as_str().unwrap_or_default().to_string();
    let admins = network_admins();
    // A role is never self-declared: `role` in the payload is unsigned and anyone can send it. Master comes
    // only from the operator's `WASM_AGENT_NETWORK_ADMINS` or a role an admin granted; every other node
    // is a guest. With no admins configured nobody is master here - closed, not open.
    let role = if admins.iter().any(|id| id == node_id) { "master".to_string() }
    else { connection.query_row("SELECT role FROM network_roles WHERE node_id=?1", [node_id], |r| r.get::<_, String>(0))
        .unwrap_or_else(|_| "guest".into()) };
    let endpoints = serde_json::to_string(&payload["endpoints"]).unwrap_or_else(|_| "[]".into());
    // A node key is per machine; a changing name means two processes share it.
    if let Ok(previous) = connection.query_row(
        "SELECT name FROM nodes WHERE node_id = ?1",
        rusqlite::params![node_id],
        |row| row.get::<_, String>(0),
    ) {
        if !name.is_empty() && previous != name {
            eprintln!(
                "[rendezvous] {} re-registered as '{name}' (was '{previous}') — same key, two processes?",
                &node_id[..node_id.len().min(12)]
            );
        }
    }
    let outcome = connection.execute(
        "INSERT INTO nodes (node_id, public_key, name, role, endpoints, resources, last_seen, registered_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7)
         ON CONFLICT(node_id) DO UPDATE SET
           public_key=excluded.public_key, name=excluded.name, role=excluded.role,
           endpoints=excluded.endpoints, resources=excluded.resources, last_seen=excluded.last_seen",
        rusqlite::params![node_id, public_key, name, role, endpoints,
            serde_json::to_string(&payload["resources"]).unwrap_or_else(|_| "null".into()), now],
    );
    // A long-running registry prunes on its own, at most hourly, riding on heartbeats it already handles.
    static LAST_PRUNE: std::sync::atomic::AtomicI64 = std::sync::atomic::AtomicI64::new(0);
    if outcome.is_ok() && now - LAST_PRUNE.load(std::sync::atomic::Ordering::Relaxed) > 3600 {
        LAST_PRUNE.store(now, std::sync::atomic::Ordering::Relaxed);
        prune(connection);
    }
    match outcome {
        Ok(_) => respond(
            stream,
            200,
            &json!({"ok": true, "node_id": node_id, "ts": now, "path": path}).to_string(),
        ),
        Err(error) => respond(stream, 500, &json!({"error": error.to_string()}).to_string()),
    }
}

fn forget(connection: &Connection, stream: &mut TcpStream, payload: &Value,
          body: &[u8], header: &dyn Fn(&str) -> String) -> std::io::Result<()> {
    let node_id = payload["node_id"].as_str().unwrap_or_default();
    // An administrator removes another node's registration: signed `forget-node|<admin>|ts|<body hash>`,
    // the same envelope as `/role`. This is the only way to clear a row whose key is gone.
    let from = header("x-wa-node");
    if !from.is_empty() && from != node_id {
        let admins = network_admins();
        if admins.is_empty() { return respond(stream, 403, "{\"error\":\"managed_service_required\"}"); }
        if !verify(connection, &from, "forget-node", header, Some(body), stream) { return Ok(()); }
        if !admins.contains(&from) { return respond(stream, 403, "{\"error\":\"administrator_required\"}"); }
        if admins.iter().any(|id| id == node_id) { return respond(stream, 400, "{\"error\":\"admin_not_forgettable\"}"); }
        if public_key_of(connection, node_id).is_none() { return respond(stream, 404, "{\"error\":\"unknown_node\"}"); }
        let _ = connection.execute("DELETE FROM nodes WHERE node_id = ?1", rusqlite::params![node_id]);
        let _ = connection.execute("DELETE FROM network_roles WHERE node_id = ?1", rusqlite::params![node_id]);
        eprintln!("[rendezvous] {} forgotten by administrator {}", &node_id[..node_id.len().min(12)], &from[..from.len().min(12)]);
        return respond(stream, 200, &json!({"ok": true, "forgotten": node_id, "by": from}).to_string());
    }
    let ts = payload["ts"].as_i64().unwrap_or(0);
    let signature = payload["signature"].as_str().unwrap_or_default();
    if now().abs_diff(ts) > 120 { return respond(stream, 401, "{\"error\":\"stale_request\"}"); }
    let Some(public_key) = public_key_of(connection, node_id) else {
        return respond(stream, 404, "{\"error\":\"unknown_node\"}");
    };
    // Only the key holder may remove its own registration.
    if !node::verify(&public_key, &format!("forget|{node_id}|{ts}"), signature) {
        return respond(stream, 401, "{\"error\":\"bad_signature\"}");
    }
    let _ = connection.execute("DELETE FROM nodes WHERE node_id = ?1", rusqlite::params![node_id]);
    respond(stream, 200, &json!({"ok": true, "forgotten": node_id}).to_string())
}

fn public_key_of(connection: &Connection, node_id: &str) -> Option<String> {
    connection
        .query_row(
            "SELECT public_key FROM nodes WHERE node_id = ?1",
            rusqlite::params![node_id],
            |row| row.get::<_, String>(0),
        )
        .ok()
}

fn lookup(connection: &Connection, node_id: &str) -> Option<Value> {
    connection
        .query_row(
            "SELECT node_id, public_key, name, role, endpoints, resources, last_seen FROM nodes WHERE node_id = ?1",
            rusqlite::params![node_id],
            |row| {
                let last_seen: i64 = row.get(6)?;
                Ok(json!({
                    "node_id": row.get::<_, String>(0)?,
                    "public_key": row.get::<_, String>(1)?,
                    "name": row.get::<_, String>(2)?,
                    "role": row.get::<_, String>(3)?,
                    "endpoints": serde_json::from_str::<Value>(&row.get::<_, String>(4)?).unwrap_or(json!([])),
                    "resources": serde_json::from_str::<Value>(&row.get::<_, Option<String>>(5)?.unwrap_or_default()).unwrap_or(Value::Null),
                    "last_seen": last_seen,
                    "online": now() - last_seen < ONLINE_WINDOW,
                }))
            },
        )
        .ok()
}

fn list(connection: &Connection) -> Value {
    let mut list: Vec<Value> = Vec::new();
    if let Ok(mut statement) = connection.prepare(
        "SELECT node_id, public_key, name, role, endpoints, resources, last_seen FROM nodes ORDER BY last_seen DESC",
    ) {
        if let Ok(rows) = statement.query_map([], |row| {
            let last_seen: i64 = row.get(6)?;
            Ok(json!({
                "node_id": row.get::<_, String>(0)?,
                "public_key": row.get::<_, String>(1)?,
                "name": row.get::<_, String>(2)?,
                "role": row.get::<_, String>(3)?,
                "endpoints": serde_json::from_str::<Value>(&row.get::<_, String>(4)?).unwrap_or(json!([])),
                "resources": serde_json::from_str::<Value>(&row.get::<_, Option<String>>(5)?.unwrap_or_default()).unwrap_or(Value::Null),
                "last_seen": last_seen,
                "online": now() - last_seen < ONLINE_WINDOW,
            }))
        }) {
            for row in rows.flatten() {
                list.push(row);
            }
        }
    }
    json!({"nodes": list})
}

fn query_value(query: &str, key: &str) -> String {
    let prefix = format!("{key}=");
    query
        .split('&')
        .find_map(|pair| pair.strip_prefix(prefix.as_str()))
        .map(|value| value.to_string())
        .unwrap_or_default()
}

fn respond(stream: &mut TcpStream, status: u16, body: &str) -> std::io::Result<()> {
    let head = format!(
        "HTTP/1.1 {status} OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\
         Cache-Control: no-store\r\nConnection: close\r\n\r\n",
        body.len()
    );
    stream.write_all(head.as_bytes())?;
    stream.write_all(body.as_bytes())?;
    stream.flush()
}

/// A refusal that TELLS the caller when to come back.
///
/// Measured 19/11 12:20-12:45 UTC: while the registry was at its connection cap it answered 503
/// too_many_connections to everyone and every caller retried at once, so the cap stayed full and the
/// fleet never converged. A 503 with no hint is an invitation to retry immediately. The hint travels
/// twice on purpose: as the Retry-After header (what an HTTP client honours without parsing a body)
/// and as retry_after_ms in the body (what this tree's own caller reads).
fn respond_retry(stream: &mut TcpStream, status: u16, body: &str, retry_after_s: u64) -> std::io::Result<()> {
    let head = format!(
        "HTTP/1.1 {status} OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\
         Cache-Control: no-store\r\nRetry-After: {retry_after_s}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    stream.write_all(head.as_bytes())?;
    stream.write_all(body.as_bytes())?;
    stream.flush()
}

/// Open connections to this listener, across every lane.
static OPEN: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
/// The listener's hard cap. One thread (and one SQLite connection) per socket, on a public port.
/// Read from the environment so a test can reproduce the 19/11 storm with a cap of 16 instead of
/// opening 256 sockets: the policy under test is the shed and the reservation, not the number.
fn max_connections() -> usize {
    std::env::var("WA_RENDEZVOUS_MAX_CONNECTIONS").ok()
        .and_then(|value| value.trim().parse::<usize>().ok())
        .filter(|value| (2..=65536).contains(value))
        .unwrap_or(256)
}
const MAX_CONNECTIONS: usize = 256;
/// Slots held back for the lanes a node MUST be able to use even while callers are storming it: its
/// relay poll (without it the node is detached, so it cannot answer anything and the queue never
/// drains) and its binding check (without it the node refuses every call). This is the reservation
/// that breaks the 19/11 deadlock: relayed calls may never occupy the whole cap.
const RESERVED_LANES: usize = 64;

/// Whether a request belongs to a lane that must never starve.
fn is_priority_lane(path: &str) -> bool {
    path == "/relay/poll"
        || path == "/relay/respond"
        // /register is the node's heartbeat. Without it the registry forgets the node, so it is a lane
        // that must never starve - and the binding tick returns before its poll when it fails, which is
        // the 19/11 deadlock in miniature (review MUST 3).
        || path == "/register"
        || path.starts_with("/bindings/")
        || path == "/lookup"
        || path == "/health"
        || path == "/service"
}

/// The load-shed decision for a request already counted in OPEN, pure so it is testable without
/// sockets. A priority lane is never shed before the hard cap. Anything else is shed once the
/// non-reserved part of the cap is gone - so under a storm the calls waiting for an answer lose the
/// connection, and the polls that would let those answers happen keep theirs.
/// The slots held back at a given cap: RESERVED_LANES at 256, and a quarter of anything smaller, so a
/// test at a cap of 16 reserves 4 and still exercises both halves of the decision. At least one slot
/// and at most cap-1 are reserved, so ordinary traffic always has somewhere to go.
fn reserved_lanes_at(cap: usize) -> usize {
    if cap <= 2 {
        return 1;
    }
    let scaled = if cap >= MAX_CONNECTIONS { RESERVED_LANES } else { cap / 4 };
    scaled.max(1).min(cap - 1)
}

/// The same decision at an explicit cap, so a test can hold the policy at 16 instead of 256.
fn shed_for_lane_at(open: usize, priority: bool, cap: usize) -> bool {
    if priority {
        return open > cap;
    }
    // saturating: ordinary traffic is never shed at open == 0, whatever the cap.
    let free = cap.saturating_sub(reserved_lanes_at(cap));
    open > free
}

/// How long a shed caller is told to wait before trying the same lane again.
const SHED_RETRY_AFTER_S: u64 = 2;
/// Relayed calls ONE caller may hold in flight against this registry. A caller that pipelines more is
/// the storm's generator, not its victim: every extra call holds a slot a poll or a binding needs.
const MAX_IN_FLIGHT_PER_CALLER: usize = 8;
/// Relayed calls that may sit queued for ONE target node. Past this the node cannot drain the queue
/// inside the answer window, so queueing more only guarantees an abandoned call.
const MAX_QUEUED_PER_TARGET: usize = 32;

/// The shed decision, pure so it can be tested without a socket or a clock.
///
/// Returns the named reason when the lane is full. Nothing has been queued at the moment this answers,
/// so the caller may send the same rid again - the hint says how long to wait first.
fn lane_refusal(caller_in_flight: usize, queued_for_target: usize) -> Option<&'static str> {
    if caller_in_flight >= MAX_IN_FLIGHT_PER_CALLER {
        return Some("relay_busy");
    }
    if queued_for_target >= MAX_QUEUED_PER_TARGET {
        return Some("relay_busy");
    }
    None
}

#[cfg(test)]
mod relay_tests {
    use super::*;

    /// 19/11: under the storm the registry answered 503 to everyone and never recovered, because the
    /// waiting calls held every slot the polls needed to answer them. The reservation is what breaks
    /// that cycle, and these numbers are the contract.
    #[test]
    fn polls_and_binding_keep_their_slots_while_relayed_calls_are_shed() {
        let cap = MAX_CONNECTIONS;
        // Below the non-reserved part of the cap, nothing is shed at all.
        assert!(!shed_for_lane_at(0, false, cap) && !shed_for_lane_at(0, true, cap));
        assert!(!shed_for_lane_at(cap - RESERVED_LANES, false, cap), "the last free non-reserved slot is usable");
        // One past it, an ordinary request is shed...
        assert!(shed_for_lane_at(cap - RESERVED_LANES + 1, false, cap),
            "an ordinary connection is shed before it can take a reserved slot");
        // ...while a poll or a binding check still gets through, right up to the hard cap.
        assert!(!shed_for_lane_at(cap - RESERVED_LANES + 1, true, cap), "a poll is never shed first");
        assert!(!shed_for_lane_at(cap, true, cap), "the reserved lanes may use the whole cap");
        assert!(shed_for_lane_at(cap + 1, true, cap), "the hard cap still applies to everyone");
        assert!(RESERVED_LANES < cap, "the reservation must leave room for ordinary traffic");
        // The same policy at a test-sized cap of 16: a quarter is reserved, so ordinary traffic stops
        // at 12 while polls keep going to 16, and nothing is shed at zero.
        assert_eq!(reserved_lanes_at(16), 4);
        assert!(!shed_for_lane_at(0, false, 16) && !shed_for_lane_at(12, false, 16));
        assert!(shed_for_lane_at(13, false, 16), "at a cap of 16, call 13 is the one that gives way");
        assert!(!shed_for_lane_at(13, true, 16), "while a poll at the same open count is served");
        assert!(shed_for_lane_at(17, true, 16), "the hard cap still applies to a poll");
        // A cap smaller than the old fixed reservation stays sane instead of reserving everything.
        assert!(!shed_for_lane_at(1, false, 2) && reserved_lanes_at(2) == 1);
    }

    /// The lanes that must never starve, and the ones that may be shed to protect them.
    #[test]
    fn the_priority_lanes_are_the_ones_that_let_an_answer_happen() {
        for path in ["/relay/poll", "/relay/respond", "/bindings/status", "/lookup", "/health", "/service", "/register"] {
            assert!(is_priority_lane(path), "{path} must never be shed before the hard cap");
        }
        // /register is the heartbeat: shedding it detaches the node, which is the storm again.
        assert!(is_priority_lane("/register"), "a heartbeat is never shed first");
        // The paths that wait for an answer are the ones that may give way.
        for path in ["/relay/send", "/nodes", "/"] {
            assert!(!is_priority_lane(path), "{path} may be shed to keep the reserved lanes open");
        }
    }

    /// Per-caller and per-target limits, before anything is queued.
    #[test]
    fn one_caller_and_one_target_cannot_fill_the_registry() {
        assert_eq!(lane_refusal(0, 0), None);
        assert_eq!(lane_refusal(MAX_IN_FLIGHT_PER_CALLER - 1, MAX_QUEUED_PER_TARGET - 1), None);
        assert_eq!(lane_refusal(MAX_IN_FLIGHT_PER_CALLER, 0), Some("relay_busy"),
            "a caller at its own limit is shed even with an empty target queue");
        assert_eq!(lane_refusal(0, MAX_QUEUED_PER_TARGET), Some("relay_busy"),
            "a target whose queue is full is not given more work to abandon");
    }

    /// The bound is the wait the caller was given, less the time the answer needs to reach it.
    #[test]
    fn the_bound_is_the_wait_the_caller_was_told() {
        assert_eq!(budget_ms(None, Duration::from_secs(45)), 42_000);
        assert_eq!(budget_ms(None, Duration::from_secs(20)), 17_000);
        // A caller may shorten the work it asks for, never lengthen the wait it holds.
        assert_eq!(budget_ms(Some(10_000), Duration::from_secs(45)), 7_000);
        assert_eq!(budget_ms(Some(300_000), Duration::from_secs(45)), 42_000);
        // Out of range is not a bound at all: what the connection allows decides.
        assert_eq!(budget_ms(Some(0), Duration::from_secs(20)), 17_000);
        assert_eq!(budget_ms(Some(900_000_000), Duration::from_secs(20)), 17_000);
        // Never a zero-second bound: the relay would hand over work with no time left on it.
        assert_eq!(budget_ms(Some(1_000), Duration::from_secs(2)), 1_000);
    }

    /// A drop is told apart from a slow call by one line, written once, with the node, the instant
    /// and the reason. A healthy poll writes nothing.
    #[test]
    fn attach_and_detach_are_named_once_with_the_reason() {
        let mut state = RelayState::default();
        let line = observe_poll(&mut state, "node-a").expect("a first poll attaches");
        println!("{line}");
        assert!(line.starts_with("[relay] attach node=node-a at="), "{line}");
        assert!(line.ends_with("reason=first poll"), "{line}");
        assert!(observe_poll(&mut state, "node-a").is_none(), "a healthy poll writes nothing");
        assert!(sweep(&mut state).is_empty(), "an attached node writes nothing");
        // 41 s without a poll: the window passed and the sweep names the detach.
        state.last_poll.insert("node-a".into(), Instant::now() - Duration::from_secs(41));
        let lines = sweep(&mut state);
        assert_eq!(lines.len(), 1, "{lines:?}");
        println!("{}", lines[0]);
        assert!(lines[0].contains("[relay] detach node=node-a at="), "{}", lines[0]);
        assert!(lines[0].contains("reason=no poll for 4"), "{}", lines[0]);
        assert!(sweep(&mut state).is_empty(), "a detach is written once");
        // Back: the attach says how long it was away.
        let back = observe_poll(&mut state, "node-a").expect("polling again attaches");
        println!("{back}");
        assert!(back.contains("reason=poll after 4"), "{back}");
    }
}

/// The retirement rules that hold without a socket: which approvals count, and who must remain.
#[cfg(test)]
mod retirement_tests {
    use super::*;

    fn ids(list: &[&str]) -> Vec<String> { list.iter().map(|id| id.to_string()).collect() }

    #[test]
    fn the_approval_message_names_the_target_the_caller_the_nonce_and_the_time() {
        let message = retirement_message("target-id", "caller-id", "nonce-1", 1_762_000_000);
        assert_eq!(message, "retire|target-id|caller-id|nonce-1|1762000000");
        assert_ne!(message, retirement_message("other-id", "caller-id", "nonce-1", 1_762_000_000),
            "an approval for one node does not approve another");
        assert_ne!(message, retirement_message("target-id", "other-caller", "nonce-1", 1_762_000_000));
        assert_ne!(message, retirement_message("target-id", "caller-id", "nonce-2", 1_762_000_000));
        assert_ne!(message, retirement_message("target-id", "caller-id", "nonce-1", 1_762_000_001));
    }

    #[test]
    fn the_caller_itself_never_counts_as_who_is_left_behind() {
        // Two administrators, one of them asking: retiring the other leaves nobody but the caller, and
        // that is the "keep the fleet" move the guard is for.
        let environment = ids(&["a", "b"]);
        assert_eq!(last_operator_problem(&environment, &[], "b", "a"), None,
            "a genuine two-operator fleet retires to one without a complaint");
        // A single-operator list: nothing can be retired from it.
        let alone = ids(&["a"]);
        assert_eq!(last_operator_problem(&alone, &[], "a", "a"), Some("last_environment_operator"));
        // Already-retired ids are not who is left.
        assert_eq!(last_operator_problem(&environment, &["a".to_string()], "b", "c"),
            Some("last_environment_operator"), "a retired row is not a standing operator");
        assert_eq!(last_operator_problem(&environment, &["b".to_string()], "a", "c"),
            Some("last_environment_operator"), "nor is the one being retired");
    }

    #[test]
    fn an_administrator_the_registry_added_is_never_why_the_environment_list_is_empty() {
        // env = [a, b]; 'x' was added at runtime by POST /operators. 'x' retiring both leaves... a and
        // b retired, and x is NOT counted as remaining: the list is empty, so the second is refused.
        let environment = ids(&["a", "b"]);
        let retired = ids(&["a"]);
        assert_eq!(last_operator_problem(&environment, &retired, "b", "x"),
            Some("last_environment_operator"),
            "a caller outside the environment's list cannot end up as its only member");
        // The same retirement asked by an environment operator is a real second-to-one move... and the
        // target is the second of two, so one is left: the caller itself. Refused as well, because the
        // caller counts only when it is in the list - and here the only other member is retired.
        assert_eq!(last_operator_problem(&environment, &["a".to_string()], "b", "a"),
            Some("last_environment_operator"));
        // With a third operator standing, the same retirement is allowed.
        let three = ids(&["a", "b", "c"]);
        assert_eq!(last_operator_problem(&three, &["a".to_string()], "b", "x"), None,
            "c is still standing, so the list is not empty");
    }

    /// A real key pair, because a signature is the only thing that can make a stored row count.
    struct Signer { key: ring::signature::Ed25519KeyPair }
    impl Signer {
        fn new() -> Self {
            use ring::signature::Ed25519KeyPair;
            let rng = ring::rand::SystemRandom::new();
            let pkcs8 = Ed25519KeyPair::generate_pkcs8(&rng).expect("a fresh key");
            Self { key: Ed25519KeyPair::from_pkcs8(pkcs8.as_ref()).expect("a usable key") }
        }
        fn public(&self) -> String { use ring::signature::KeyPair; node::hex(self.key.public_key().as_ref()) }
        fn approval(&self, approver: &str, target: &str, caller: &str, nonce: &str, ts: i64) -> String {
            let signature = node::hex(self.key.sign(retirement_message(target, caller, nonce, ts).as_bytes()).as_ref());
            json!({"node_id": approver, "ts": ts, "signature": signature, "caller": caller, "nonce": nonce}).to_string()
        }
    }

    fn stored(signer: &Signer, target: &str, caller: &str, environment: &[String], keys: &[(String, String)],
              at: i64, ts: i64) -> bool {
        let approval = signer.approval("approver", target, caller, "nonce-1", ts);
        stored_retirement_holds(target, caller, "approver", &approval, at, environment, keys)
    }

    #[test]
    fn a_stored_retirement_without_its_proof_is_not_applied() {
        let signer = &Signer::new();
        let environment = ids(&["approver", "operator-a"]);
        let keys = vec![("approver".to_string(), signer.public())];
        let at = 1_762_000_000;
        // No approval at all (a row written by hand, or one from before the proof existed).
        assert!(!stored_retirement_holds("operator-a", "caller", "", "", at, &environment, &keys));
        assert!(!stored_retirement_holds("operator-a", "caller", "approver", "", at, &environment, &keys));
        // An approval with a signature that is not one.
        let not_a_signature = r#"{"node_id":"approver","ts":1762000000,"signature":"00ff","caller":"caller","nonce":"n"}"#;
        assert!(!stored_retirement_holds("operator-a", "caller", "approver", not_a_signature, at, &environment, &keys),
            "a signature that does not verify retires nobody");
        // An approval whose stored caller does not match the row it sits in: the signature covers the
        // caller, so one row's approval cannot be moved onto another row.
        let for_caller = signer.approval("approver", "operator-a", "caller", "nonce-1", at);
        assert!(!stored_retirement_holds("operator-a", "somebody-else", "approver", &for_caller, at, &environment, &keys),
            "the signature names the caller, so one row cannot be moved to another");
        // The genuine article.
        assert!(stored(signer, "operator-a", "caller", &environment, &keys, at, at),
            "a valid second signature is applied");
    }

    // The MEDIUM the review measured (18/11): the approver came from whatever the row said, with a key
    // read from the same database - so a database write retired an environment operator.
    #[test]
    fn an_approver_the_environment_does_not_name_retires_nobody_whatever_the_database_says() {
        let signer = &Signer::new();
        let at = 1_762_000_000;
        let saved = vec![("approver".to_string(), signer.public())];
        // The right key and a valid signature, but the approver is not an environment administrator.
        let environment = ids(&["approver-was-removed", "operator-a"]);
        assert!(!stored(signer, "operator-a", "caller", &environment, &saved, at, at),
            "an approver outside WASM_AGENT_NETWORK_ADMINS cannot retire an environment operator");
        // The key the environment names is the only one that counts: a key the DATABASE holds for the
        // same id (an attacker who could write the nodes table) proves nothing about who holds the
        // private half.
        let environment = ids(&["approver", "operator-a"]);
        assert!(!stored(signer, "operator-a", "caller", &environment, &[], at, at),
            "a key the environment does not name is not a key");
        let stranger = vec![("approver".to_string(), "11".repeat(32))];
        assert!(!stored(signer, "operator-a", "caller", &environment, &stranger, at, at),
            "another key under the administrator's id does not verify this signature");
    }

    // The window: an approval is contemporary with the retirement it approved, not good forever.
    #[test]
    fn an_approval_outside_the_retirement_window_is_not_applied() {
        let signer = &Signer::new();
        let environment = ids(&["approver", "operator-a"]);
        let keys = vec![("approver".to_string(), signer.public())];
        let at = 1_762_000_000;
        assert!(stored(signer, "operator-a", "caller", &environment, &keys, at, at - APPROVAL_WINDOW_SECONDS),
            "an approval made just before the retirement is inside the window");
        assert!(!stored(signer, "operator-a", "caller", &environment, &keys, at, at - APPROVAL_WINDOW_SECONDS - 1),
            "an old signature over the same words is not this retirement's approval");
        assert!(!stored(signer, "operator-a", "caller", &environment, &keys, at, at + APPROVAL_WINDOW_SECONDS + 1),
            "and neither is one minted long after it");
    }
}
