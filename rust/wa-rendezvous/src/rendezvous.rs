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
    // Schema first, on a short-lived connection.
    match Connection::open(db_path) {
        Ok(connection) => {
            if let Err(error) = connection.execute_batch(
                "PRAGMA journal_mode=WAL;
                 CREATE TABLE IF NOT EXISTS nodes (
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
                 );",
            ) {
                eprintln!("[rendezvous] schema: {error}");
                return;
            }
            if let Err(error)=bindings::schema(&connection){eprintln!("[rendezvous] binding schema: {error}");return;}
            // SQLite has no `ADD COLUMN IF NOT EXISTS`. Existing registries need this once;
            // subsequent starts harmlessly report the duplicate column and continue.
            let _ = connection.execute("ALTER TABLE nodes ADD COLUMN resources TEXT", []);
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

    if let Ok(connection) = Connection::open(db_path) { prune(&connection); }

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
    static OPEN: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    const MAX_CONNECTIONS: usize = 256;
    for stream in listener.incoming() {
        let Ok(mut stream) = stream else { continue };
        if OPEN.fetch_add(1, std::sync::atomic::Ordering::SeqCst) >= MAX_CONNECTIONS {
            OPEN.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
            let _ = respond(&mut stream, 503, "{\"error\":\"too_many_connections\"}");
            continue;
        }
        let db = db_path.to_string();
        let relay = relay.clone();
        std::thread::spawn(move || {
            let _ = stream.set_write_timeout(Some(Duration::from_secs(15)));
            if let Err(error) = handle(&db, &mut stream, &relay) {
                eprintln!("[rendezvous] connection: {error}");
            }
            OPEN.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
        });
    }
}

fn handle(db_path: &str, stream: &mut TcpStream, relay: &Arc<Mutex<RelayState>>) -> std::io::Result<()> {
    let connection = match Connection::open(db_path) {
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
    std::env::var("WASM_AGENT_NETWORK_ADMINS").unwrap_or_default()
        .split(',').map(str::trim).filter(|s| !s.is_empty()).map(str::to_string).collect()
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
        let _ = respond(stream, 401, "{\"error\":\"bad_signature\"}");
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
        let _ = respond(stream, 401, "{\"error\":\"bad_signature\"}");
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

#[cfg(test)]
mod relay_tests {
    use super::*;

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
