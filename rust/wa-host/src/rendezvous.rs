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
use rusqlite::Connection;
use serde_json::{json, Value};
use std::collections::{HashMap, VecDeque};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant};

const ONLINE_WINDOW: i64 = 180; // seconds
const POLL_WAIT: Duration = Duration::from_secs(25);
const SEND_WAIT: Duration = Duration::from_secs(45);
// How long to hold a request for a node that is not attached at all. The node
// attaches by polling, so waiting is usually just waiting for the next poll -
// and failing immediately turned a four-second pause into a failed build.
const ATTACH_HOLD: Duration = Duration::from_secs(20);
const MAX_BODY: usize = 4_000_000;

#[derive(Default)]
struct RelayState {
    queue: HashMap<String, VecDeque<Value>>,
    waiting: HashMap<String, mpsc::Sender<(u16, String)>>,
    /// When each node last polled. A node that is not attached cannot be
    /// reached, so say so immediately instead of queueing for a minute.
    last_poll: HashMap<String, Instant>,
    /// Request ids already queued, so a caller that retries after a timeout
    /// waits on the same request instead of running the action twice.
    issued: HashMap<String, Instant>,
    /// Completed results kept briefly so a retry can still collect them.
    results: HashMap<String, ((u16, String), Instant)>,
    // Request IDs are scoped to their authenticated sender, recipient and exact envelope.
    owners: HashMap<String, (String, String, String)>,
    next_id: u64,
}

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or(0)
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

    let listener = match TcpListener::bind((bind, port)) {
        Ok(listener) => listener,
        Err(error) => {
            eprintln!("[rendezvous] bind {bind}:{port}: {error}");
            return;
        }
    };
    eprintln!("[rendezvous] listening on {bind}:{port} (db {db_path})");

    let relay: Arc<Mutex<RelayState>> = Arc::new(Mutex::new(RelayState::default()));
    // One thread per connection: long polls must not block the registry.
    for stream in listener.incoming() {
        let Ok(mut stream) = stream else { continue };
        let db = db_path.to_string();
        let relay = relay.clone();
        std::thread::spawn(move || {
            if let Err(error) = handle(&db, &mut stream, &relay) {
                eprintln!("[rendezvous] connection: {error}");
            }
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

    stream.set_read_timeout(Some(Duration::from_secs(10)))?;
    let mut data = Vec::new();
    let mut chunk = [0u8; 16384];
    let (method, target, headers, body) = loop {
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
        return respond(stream, 200, &json!({"protocol": 1,
            "enrollment_ready": !admins.is_empty() && operators.len() == admins.len(),
            "operators": operators}).to_string());
    }
    if path == "/role" && method == "POST" {
        return grant_role(&connection, stream, &payload, &body, &header);
    }

    // ---- registry --------------------------------------------------------
    if (path == "/register" || path == "/heartbeat") && method == "POST" {
        return register(&connection, stream, &payload, &path);
    }
    if path == "/forget" && method == "POST" {
        return forget(&connection, stream, &payload);
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
                node["relay_attached"] = json!(relay.lock().unwrap().last_poll.get(&node_id)
                    .map(|at| at.elapsed() < Duration::from_secs(40)).unwrap_or(false));
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
        let deadline = Instant::now() + POLL_WAIT;
        loop {
            let next = {
                let mut state = relay.lock().unwrap();
                state.last_poll.insert(node_id.clone(), Instant::now());
                state.queue.get_mut(&node_id).and_then(|queue| queue.pop_front())
            };
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
        {
            let mut state = relay.lock().unwrap();
            if !state.owners.get(&id).map(|owner| owner.1 == node_id).unwrap_or(false) {
                return respond(stream, 403, "{\"error\":\"not_request_recipient\"}");
            }
            if state.results.contains_key(&id) { return respond(stream, 409, "{\"error\":\"already_completed\"}"); }
            state.issued.remove(&id);
            // Keep the result briefly even if nobody is waiting right now,
            // so a caller that timed out can still collect it.
            state.results.insert(id.clone(), ((status, body.clone()), Instant::now()));
            if let Some(sender) = state.waiting.remove(&id) {
                let _ = sender.send((status, body));
            }
        }
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
        let attached_at_start = {
            let mut state = relay.lock().unwrap();
            state.results.retain(|_, (_, at)| at.elapsed() < Duration::from_secs(120));
            state.issued.retain(|_, at| at.elapsed() < Duration::from_secs(120));
            let live: std::collections::HashSet<String> = state.issued.keys().chain(state.results.keys()).cloned().collect();
            state.owners.retain(|id, _| live.contains(id));
            for queue in state.queue.values_mut() { queue.retain(|r| r["id"].as_str().map(|id| live.contains(id)).unwrap_or(false)); }
            let owner = (from.clone(), to.clone(), body_hash(&body));
            if state.owners.get(&id).map(|old| old != &owner).unwrap_or(false) {
                return respond(stream, 409, "{\"error\":\"request_id_conflict\"}");
            }
            if let Some(((status, result), _)) = state.results.get(&id) {
                return respond(stream, 200, &json!({"ok":true,"status":status,"body":result,"replayed":true}).to_string());
            }
            if state.waiting.contains_key(&id) {
                return respond(stream, 409, "{\"error\":\"request_in_flight\"}");
            }
            state.waiting.insert(id.clone(), tx);
            if !state.issued.contains_key(&id) {
                state.owners.insert(id.clone(), owner);
                state.issued.insert(id.clone(), Instant::now());
                state.queue.entry(to.clone()).or_default().push_back(json!({
                    "id":id,"from":from,"method":payload["method"].as_str().unwrap_or("POST"),
                    "path":payload["path"].as_str().unwrap_or("/"),"headers":payload["headers"].clone(),
                    "body":payload["body"].as_str().unwrap_or("")
                }));
            }
            state.last_poll.get(&to).map(|at| at.elapsed() < Duration::from_secs(40)).unwrap_or(false)
        };
        let hold = if attached_at_start { SEND_WAIT } else { ATTACH_HOLD };
        match rx.recv_timeout(hold) {
            Ok((status, body)) => {
                relay.lock().unwrap().waiting.remove(&id);
                respond(stream, 200, &json!({"ok": true, "status": status, "body": body}).to_string())
            }
            Err(_) => {
                // Two different situations, and the caller needs to tell them
                // apart: a node that never attached (retry when it is back) and a
                // node that is attached but did not answer in time (it is busy -
                // the action may still be running, so do not repeat it blindly).
                let attached_now = {
                    let state = relay.lock().unwrap();
                    state
                        .last_poll
                        .get(&to)
                        .map(|at| at.elapsed() < Duration::from_secs(40))
                        .unwrap_or(false)
                };
                relay.lock().unwrap().waiting.remove(&id);
                respond(
                    stream,
                    504,
                    &json!({
                        "error": if attached_now { "node_no_answer" } else { "node_not_attached" },
                        "rid": id,
                        "to": to,
                        "waited_ms": hold.as_millis() as u64,
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
        let state = relay.lock().unwrap();
        let queue: Vec<Value> = state
            .queue
            .iter()
            .filter(|(_, entries)| !entries.is_empty())
            .map(|(node, entries)| json!({"node_id": node, "queued": entries.len()}))
            .collect();
        let attached: Vec<Value> = state
            .last_poll
            .iter()
            .filter(|(_, at)| at.elapsed() < Duration::from_secs(40))
            .map(|(node, _)| json!(node))
            .collect();
        respond(
            stream,
            200,
            &json!({"ok": true, "queued": queue, "waiting": state.waiting.len(), "attached": attached})
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

fn network_admins() -> Vec<String> {
    std::env::var("WASM_AGENT_NETWORK_ADMINS").unwrap_or_default()
        .split(',').map(str::trim).filter(|s| !s.is_empty()).map(str::to_string).collect()
}
fn body_hash(bytes: &[u8]) -> String {
    node::hex(ring::digest::digest(&ring::digest::SHA256, bytes).as_ref())
}
fn is_master(connection: &Connection, id: &str) -> bool {
    lookup(connection, id).map(|n| n["role"] == "master" || n["role"] == "admin").unwrap_or(false)
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
    let result = (|| -> rusqlite::Result<()> {
        let tx = connection.unchecked_transaction()?;
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
    if !node::verify(public_key, &node::announcement(node_id, ts as u64), signature) {
        return respond(stream, 401, "{\"error\":\"bad_signature\"}");
    }
    let now = now();
    let name = payload["name"].as_str().unwrap_or_default().to_string();
    let admins = network_admins();
    let role = if admins.is_empty() {
        payload["role"].as_str().unwrap_or("guest").to_string()
    } else if admins.iter().any(|id| id == node_id) { "master".into() }
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
        "INSERT INTO nodes (node_id, public_key, name, role, endpoints, last_seen, registered_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6)
         ON CONFLICT(node_id) DO UPDATE SET
           public_key=excluded.public_key, name=excluded.name, role=excluded.role,
           endpoints=excluded.endpoints, last_seen=excluded.last_seen",
        rusqlite::params![node_id, public_key, name, role, endpoints, now],
    );
    match outcome {
        Ok(_) => respond(
            stream,
            200,
            &json!({"ok": true, "node_id": node_id, "ts": now, "path": path}).to_string(),
        ),
        Err(error) => respond(stream, 500, &json!({"error": error.to_string()}).to_string()),
    }
}

fn forget(connection: &Connection, stream: &mut TcpStream, payload: &Value) -> std::io::Result<()> {
    let node_id = payload["node_id"].as_str().unwrap_or_default();
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
            "SELECT node_id, public_key, name, role, endpoints, last_seen FROM nodes WHERE node_id = ?1",
            rusqlite::params![node_id],
            |row| {
                let last_seen: i64 = row.get(5)?;
                Ok(json!({
                    "node_id": row.get::<_, String>(0)?,
                    "public_key": row.get::<_, String>(1)?,
                    "name": row.get::<_, String>(2)?,
                    "role": row.get::<_, String>(3)?,
                    "endpoints": serde_json::from_str::<Value>(&row.get::<_, String>(4)?).unwrap_or(json!([])),
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
        "SELECT node_id, public_key, name, role, endpoints, last_seen FROM nodes ORDER BY last_seen DESC",
    ) {
        if let Ok(rows) = statement.query_map([], |row| {
            let last_seen: i64 = row.get(5)?;
            Ok(json!({
                "node_id": row.get::<_, String>(0)?,
                "public_key": row.get::<_, String>(1)?,
                "name": row.get::<_, String>(2)?,
                "role": row.get::<_, String>(3)?,
                "endpoints": serde_json::from_str::<Value>(&row.get::<_, String>(4)?).unwrap_or(json!([])),
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
