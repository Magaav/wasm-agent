//! Rendezvous: a tiny always-on registry that lets nodes find each other.
//!
//! It stores `node_id -> {public_key, name, role, endpoints, last_seen}` and
//! verifies every announcement with the node's ed25519 key. It never carries
//! traffic, so it can stay small; a node that is always on (e.g. an Oracle
//! instance) is enough. Nodes dial **out** to it, so no node needs an inbound
//! port.
use crate::node;
use rusqlite::Connection;
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};

const ONLINE_WINDOW: i64 = 180; // seconds

pub fn run(port: u16, db_path: &str) {
    let connection = match Connection::open(db_path) {
        Ok(connection) => connection,
        Err(error) => {
            eprintln!("[rendezvous] open {db_path}: {error}");
            return;
        }
    };
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
    let listener = match TcpListener::bind(("0.0.0.0", port)) {
        Ok(listener) => listener,
        Err(error) => {
            eprintln!("[rendezvous] bind 0.0.0.0:{port}: {error}");
            return;
        }
    };
    eprintln!("[rendezvous] listening on 0.0.0.0:{port} (db {db_path})");
    for stream in listener.incoming() {
        if let Ok(mut stream) = stream {
            let _ = handle(&connection, &mut stream);
        }
    }
}

fn handle(connection: &Connection, stream: &mut TcpStream) -> std::io::Result<()> {
    let mut data = Vec::new();
    let mut chunk = [0u8; 8192];
    let (method, target, body) = loop {
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
            for line in lines {
                if let Some(value) = line.to_ascii_lowercase().strip_prefix("content-length:") {
                    length = value.trim().parse().unwrap_or(0);
                }
            }
            if data.len() >= end + 4 + length {
                break (method, target, data[end + 4..end + 4 + length].to_vec());
            }
        }
        if data.len() > 1_000_000 {
            return Ok(());
        }
    };

    let (path, query) = match target.split_once('?') {
        Some((path, query)) => (path.to_string(), query.to_string()),
        None => (target.clone(), String::new()),
    };
    let payload: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);

    if path == "/health" {
        return respond(stream, 200, "{\"ok\":true}");
    }
    if (path == "/register" || path == "/heartbeat") && method == "POST" {
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
        let outcome = connection.execute(
            "INSERT INTO nodes (node_id, public_key, name, role, endpoints, last_seen, registered_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6)
             ON CONFLICT(node_id) DO UPDATE SET
               public_key=excluded.public_key, name=excluded.name, role=excluded.role,
               endpoints=excluded.endpoints, last_seen=excluded.last_seen",
            rusqlite::params![node_id, public_key, name, role, endpoints, now],
        );
        return match outcome {
            Ok(_) => respond(stream, 200, &json!({"ok": true, "node_id": node_id, "ts": now}).to_string()),
            Err(error) => respond(stream, 500, &json!({"error": error.to_string()}).to_string()),
        };
    }
    if path == "/lookup" {
        let node_id = query
            .split('&')
            .find_map(|pair| pair.strip_prefix("node_id="))
            .unwrap_or("");
        return match lookup(connection, node_id) {
            Some(node) => respond(stream, 200, &node.to_string()),
            None => respond(stream, 404, "{\"error\":\"unknown_node\"}"),
        };
    }
    if path == "/nodes" {
        let mut statement = match connection
            .prepare("SELECT node_id, public_key, name, role, endpoints, last_seen FROM nodes ORDER BY last_seen DESC")
        {
            Ok(statement) => statement,
            Err(error) => return respond(stream, 500, &json!({"error": error.to_string()}).to_string()),
        };
        let mut list: Vec<Value> = Vec::new();
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
        return respond(stream, 200, &json!({"nodes": list}).to_string());
    }
    respond(stream, 404, "{\"error\":\"not_found\"}")
}

fn lookup(connection: &Connection, node_id: &str) -> Option<Value> {
    let mut statement = connection
        .prepare("SELECT node_id, public_key, name, role, endpoints, last_seen FROM nodes WHERE node_id = ?1")
        .ok()?;
    statement
        .query_row(rusqlite::params![node_id], |row| {
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
        })
        .ok()
}

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or(0)
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
