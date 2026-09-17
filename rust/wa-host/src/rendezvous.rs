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
                 );",
            ) {
                eprintln!("[rendezvous] schema: {error}");
                return;
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

    // ---- registry --------------------------------------------------------
    if (path == "/register" || path == "/heartbeat") && method == "POST" {
        return register(&connection, stream, &payload, &path);
    }
    if path == "/forget" && method == "POST" {
        return forget(&connection, stream, &payload);
    }
    if path == "/lookup" {
        let node_id = query_value(&query, "node_id");
        return match lookup(&connection, &node_id) {
            Some(node) => respond(stream, 200, &node.to_string()),
            None => respond(stream, 404, "{\"error\":\"unknown_node\"}"),
        };
    }
    if path == "/nodes" {
        return respond(stream, 200, &list(&connection).to_string());
    }

    // ---- relay -----------------------------------------------------------
    if path == "/relay/poll" {
        let node_id = query_value(&query, "node_id");
        if !verify(&connection, &node_id, "relay-poll", &header, stream) {
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
        if !verify(&connection, &node_id, "relay-respond", &header, stream) {
            return Ok(());
        }
        let id = payload["id"].as_str().unwrap_or_default().to_string();
        let status = payload["status"].as_u64().unwrap_or(200) as u16;
        let body = payload["body"].as_str().unwrap_or_default().to_string();
        {
            let mut state = relay.lock().unwrap();
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
        if !verify(&connection, &from, "relay-send", &header, stream) {
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
        // Idempotent by request id: a retry never re-runs the action.
        let id = payload["rid"].as_str().filter(|value| !value.is_empty()).map(str::to_string);
        let id = id.unwrap_or_else(|| {
            let mut state = relay.lock().unwrap();
            state.next_id += 1;
            format!("r{}", state.next_id)
        });
        {
            let mut state = relay.lock().unwrap();
            // Drop abandoned relay entries: a caller that stopped polling leaves
            // results and issued ids behind, and they are only useful for a
            // couple of minutes.
            state.results.retain(|_, (_, at)| at.elapsed() < Duration::from_secs(120));
            state.issued.retain(|_, at| at.elapsed() < Duration::from_secs(120));
            if let Some(((status, body), _)) = state.results.remove(&id) {
                return respond(
                    stream,
                    200,
                    &json!({"ok": true, "status": status, "body": body, "replayed": true}).to_string(),
                );
            }
        }
        // Hold rather than fail when the target is not attached. It attaches by
        // polling, so for the caller the difference is "this waited four seconds"
        // rather than "this failed" - and nothing is lost if it never attaches,
        // because the answer is retryable and the id is idempotent: a repeat
        // re-fetches the result instead of re-running the action.
        let attached_at_start = {
            let state = relay.lock().unwrap();
            state
                .last_poll
                .get(&to)
                .map(|at| at.elapsed() < Duration::from_secs(40))
                .unwrap_or(false)
        };
        let (tx, rx) = mpsc::channel();
        let request = json!({
            "id": id,
            "from": from,
            "method": payload["method"].as_str().unwrap_or("POST"),
            "path": payload["path"].as_str().unwrap_or("/"),
            "headers": payload["headers"].clone(),
            "body": payload["body"].as_str().unwrap_or(""),
        });
        {
            let mut state = relay.lock().unwrap();
            state.waiting.insert(id.clone(), tx);
            // Only queue if this id has not already been issued.
            if !state.issued.contains_key(&id) {
                state.issued.insert(id.clone(), Instant::now());
                state.queue.entry(to.clone()).or_default().push_back(request);
            }
        }
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

/// Verify a signed relay call: `action|node_id|ts`.
fn verify(
    connection: &Connection,
    node_id: &str,
    action: &str,
    header: &dyn Fn(&str) -> String,
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
    if !node::verify(&stored, &format!("{action}|{node_id}|{ts_value}"), &signature) {
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
    if !node::verify(public_key, &node::announcement(node_id, ts as u64), signature) {
        return respond(stream, 401, "{\"error\":\"bad_signature\"}");
    }
    let now = now();
    let name = payload["name"].as_str().unwrap_or_default().to_string();
    let role = payload["role"].as_str().unwrap_or("guest").to_string();
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
