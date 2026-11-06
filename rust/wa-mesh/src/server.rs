//! The direct transport, listener side: `/mesh/health` and `/mesh/call`.
//!
//! The listener does the same three checks the caller made — who is this, may they, and is this
//! really for me — and it does them against *its own* roster and `policy.json`, never against the
//! caller's claim. Only then does it hand the call to the [`Handler`], which is the node's business:
//! this crate knows how to authorize a call, not how to run a capability.
//!
//! Refusals before authentication are unsigned (they cannot be signed: a reply signature binds an
//! answer to a verified request) and carry one allow-listed code. Once the caller is authenticated,
//! every answer is signed, including a denial — a denial from the target is a decision, and the
//! caller should be able to tell it apart from something the network said.
use crate::audit::{Event, Sink};
use crate::hierarchy::{authorize, Verb};
use crate::http;
use crate::identity::{verify, Identity};
use crate::policy::MeshPolicy;
use crate::roster::{Roster, RosterNode};
use crate::wire::{self, MeshCall, MeshReply};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::Write;
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// What a capability call looks like once it is authenticated and authorized.
#[derive(Debug, Clone)]
pub struct Call {
    pub from: RosterNode,
    pub to: RosterNode,
    pub verb: Verb,
    pub capability: String,
    pub args: Value,
    pub request_id: String,
    pub inner: crate::client::Inner,
}

/// What the node answers with: its own status and body, exactly as its `/node/call` would.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Reply {
    pub status: u16,
    pub body: String,
}

impl Reply {
    pub fn ok(body: impl Into<String>) -> Reply {
        Reply { status: 200, body: body.into() }
    }

    pub fn error(status: u16, code: &str) -> Reply {
        Reply { status, body: json!({ "error": code }).to_string() }
    }
}

/// The node's side of a mesh call. One implementation per mount; the tests use an echo.
pub trait Handler: Send + Sync {
    fn handle(&self, call: &Call) -> Reply;
}

pub struct ServerConfig {
    /// `host:port`; `127.0.0.1:0` binds an ephemeral port (the tests use it).
    pub bind: String,
    pub identity: Identity,
    pub roster: Roster,
    pub policy: MeshPolicy,
    pub handler: Arc<dyn Handler>,
    pub audit: Arc<dyn Sink>,
    pub max_body: usize,
    pub io_timeout: Duration,
    pub max_connections: usize,
}

impl ServerConfig {
    pub fn new(bind: impl Into<String>, identity: Identity, roster: Roster, policy: MeshPolicy, handler: Arc<dyn Handler>, audit: Arc<dyn Sink>) -> ServerConfig {
        ServerConfig {
            bind: bind.into(),
            identity,
            roster,
            policy,
            handler,
            audit,
            max_body: http::MAX_BODY,
            io_timeout: Duration::from_secs(30),
            max_connections: 32,
        }
    }
}

struct State {
    identity: Identity,
    roster: Roster,
    policy: MeshPolicy,
    handler: Arc<dyn Handler>,
    audit: Arc<dyn Sink>,
    roster_status: Result<(), String>,
    seen: Mutex<HashMap<String, u64>>,
    max_body: usize,
    io_timeout: Duration,
    connections: AtomicUsize,
    max_connections: usize,
}

pub struct Server {
    addr: SocketAddr,
    stop: Arc<AtomicBool>,
    join: Option<std::thread::JoinHandle<()>>,
}

impl Server {
    pub fn start(config: ServerConfig) -> Result<Server, String> {
        let listener = TcpListener::bind(config.bind.as_str())
            .map_err(|error| format!("bind {} failed: {error}", config.bind))?;
        let addr = listener.local_addr().map_err(|error| error.to_string())?;
        let roster_status = config
            .roster
            .verify(&config.policy.roster_key, wire::now_seconds())
            .map_err(|error| error.0);
        let state = Arc::new(State {
            identity: config.identity,
            roster: config.roster,
            policy: config.policy,
            handler: config.handler,
            audit: config.audit,
            roster_status,
            seen: Mutex::new(HashMap::new()),
            max_body: config.max_body,
            io_timeout: config.io_timeout,
            connections: AtomicUsize::new(0),
            max_connections: config.max_connections,
        });
        let stop = Arc::new(AtomicBool::new(false));
        let accept_stop = stop.clone();
        let join = std::thread::Builder::new()
            .name("wa-mesh-listen".into())
            .spawn(move || accept_loop(listener, state, accept_stop))
            .map_err(|error| error.to_string())?;
        Ok(Server { addr, stop, join: Some(join) })
    }

    pub fn local_addr(&self) -> SocketAddr {
        self.addr
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(join) = self.join.take() {
            // The accept loop is blocked in `accept`; one throwaway connection is what wakes it.
            let _ = TcpStream::connect_timeout(&self.addr, Duration::from_millis(250));
            let _ = join.join();
        }
    }
}

fn accept_loop(listener: TcpListener, state: Arc<State>, stop: Arc<AtomicBool>) {
    for incoming in listener.incoming() {
        if stop.load(Ordering::SeqCst) {
            break;
        }
        let Ok(stream) = incoming else { continue };
        if state.connections.fetch_add(1, Ordering::SeqCst) >= state.max_connections {
            state.connections.fetch_sub(1, Ordering::SeqCst);
            let mut stream = stream;
            let _ = http::write_response(
                &mut stream,
                503,
                &[],
                br#"{"error":"handler_unavailable","reason":"too_many_connections"}"#,
            );
            continue;
        }
        let state = state.clone();
        std::thread::Builder::new()
            .name("wa-mesh-conn".into())
            .spawn(move || {
                handle_connection(&state, stream);
                state.connections.fetch_sub(1, Ordering::SeqCst);
            })
            .ok();
    }
}

fn handle_connection(state: &Arc<State>, mut stream: TcpStream) {
    let _ = stream.set_nodelay(true);
    let _ = stream.set_read_timeout(Some(state.io_timeout));
    let _ = stream.set_write_timeout(Some(state.io_timeout));
    let request = match http::read_request(&mut stream, state.max_body) {
        Ok(Some(request)) => request,
        Ok(None) => return,
        Err(error) => {
            let status = if error == "too_large" { 413 } else { 400 };
            let code = if error == "too_large" { "too_large" } else { "bad_request" };
            let _ = http::write_response(&mut stream, status, &[], json!({"error": code}).to_string().as_bytes());
            return;
        }
    };
    let (status, headers, body) = route(state, &request);
    if http::write_response(&mut stream, status, &headers, body.as_bytes()).is_err() {
        let _ = stream.flush();
    }
}

fn route(state: &Arc<State>, request: &http::Request) -> (u16, Vec<(String, String)>, String) {
    match (request.method.as_str(), request.path.as_str()) {
        ("GET", "/mesh/health") => (200, Vec::new(), health(state).to_string()),
        ("POST", "/mesh/call") => call(state, request),
        _ => (404, Vec::new(), json!({"error": "not_found"}).to_string()),
    }
}

fn health(state: &Arc<State>) -> Value {
    let me = state.roster.node(&state.identity.node_id);
    json!({
        "mesh": wire::SCHEMA,
        "node_id": state.identity.node_id,
        "public_key": state.identity.public_key,
        "name": me.map(|node| node.name.clone()).unwrap_or_default(),
        "level": me.map(|node| node.level),
        "fleet": state.roster.fleet,
        "roster_fingerprint": state.roster.fingerprint(),
        "roster_verified": state.roster_status.is_ok(),
        "roster_status": match &state.roster_status { Ok(()) => "verified".to_string(), Err(error) => error.clone() },
        "grants": state.policy.grants.len(),
        "unsigned": "this answer names a node, it does not authenticate one",
    })
}

fn unsigned(status: u16, code: &str) -> (u16, Vec<(String, String)>, String) {
    (status, Vec::new(), json!({"error": code}).to_string())
}

fn call(state: &Arc<State>, request: &http::Request) -> (u16, Vec<(String, String)>, String) {
    let now_s = wire::now_seconds();
    let started = Instant::now();
    if let Err(reason) = &state.roster_status {
        return (503, Vec::new(), json!({"error": "roster_unverified", "reason": reason}).to_string());
    }
    if request.header("x-wa-mesh") != Some("1") {
        return unsigned(400, "not_mesh");
    }
    let body = request.body_text();
    let call = match MeshCall::parse(&body) {
        Ok(call) => call,
        Err(_) => return unsigned(400, "bad_request"),
    };
    let header_node = request.header("x-wa-node").unwrap_or_default();
    let header_key = request.header("x-wa-pub").unwrap_or_default();
    if header_node != call.from_node_id {
        return unsigned(400, "bad_request");
    }
    let Some(caller) = state.roster.node(&call.from_node_id).cloned() else {
        return unsigned(403, "unknown_caller");
    };
    if header_key != caller.public_key {
        return unsigned(401, "bad_signature");
    }
    let ts = match request.header("x-wa-ts").and_then(|value| value.parse::<u64>().ok()) {
        Some(ts) => ts,
        None => return unsigned(400, "bad_request"),
    };
    let signature = request.header("x-wa-sig").unwrap_or_default();
    if !verify(
        &caller.public_key,
        &MeshCall::call_message(&call.from_node_id, ts, &body),
        signature,
    ) {
        return unsigned(401, "bad_signature");
    }
    if !wire::is_fresh(ts, now_s) {
        return unsigned(408, "stale_request");
    }
    if is_replayed(state, &caller.node_id, ts, signature, now_s) {
        return unsigned(409, "replayed_request");
    }
    if call.to_node_id != state.identity.node_id {
        return unsigned(403, "wrong_target");
    }
    let Some(target) = state.roster.node(&state.identity.node_id).cloned() else {
        return unsigned(503, "handler_unavailable");
    };
    let verb = Verb::from_capability(&call.capability);
    let verdict = authorize(&state.policy, &caller, &target, verb, now_s);
    let refuse = |code: &str, reason: &str, detail: &str| -> (u16, Vec<(String, String)>, String) {
        let reply = MeshReply {
            schema: wire::SCHEMA,
            request_id: call.request_id.clone(),
            from_node_id: target.node_id.clone(),
            ok: false,
            status: None,
            body: None,
            error: Some(code.to_string()),
            reason: Some(reason.to_string()),
            detail: Some(detail.to_string()),
            verb: Some(verb.as_str().to_string()),
        };
        signed_reply(&state.identity, &target.node_id, &caller.node_id, &reply)
    };
    if !verdict.is_allow() {
        Event::new("recv", &caller.node_id, &target.node_id)
            .levels(Some(caller.level), Some(target.level))
            .verb(verb.as_str())
            .verdict("deny", verdict.reason)
            .outcome(false, Some(403), started.elapsed().as_millis() as u64, 1)
            .emit(state.audit.as_ref());
        return refuse("mesh_denied", verdict.reason, &verdict.detail);
    }
    let inner = crate::client::Inner { body: call.inner_body.clone(), headers: call.inner_headers.clone() };
    let request = Call {
        from: caller.clone(),
        to: target.clone(),
        verb,
        capability: call.capability.clone(),
        args: call.args.clone(),
        request_id: call.request_id.clone(),
        inner,
    };
    let handled = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        state.handler.handle(&request)
    }));
    let reply = match handled {
        Ok(reply) => reply,
        Err(_) => {
            Event::new("recv", &caller.node_id, &target.node_id)
                .levels(Some(caller.level), Some(target.level))
                .verb(verb.as_str())
                .verdict("deny", "handler_failed")
                .outcome(false, Some(500), started.elapsed().as_millis() as u64, 1)
                .emit(state.audit.as_ref());
            return unsigned(500, "internal_error");
        }
    };
    Event::new("recv", &caller.node_id, &target.node_id)
        .levels(Some(caller.level), Some(target.level))
        .verb(verb.as_str())
        .verdict("allow", verdict.reason)
        .outcome(reply.status == 200, Some(reply.status), started.elapsed().as_millis() as u64, 1)
        .emit(state.audit.as_ref());
    let mesh_reply = MeshReply {
        schema: wire::SCHEMA,
        request_id: call.request_id,
        from_node_id: target.node_id.clone(),
        ok: true,
        status: Some(reply.status),
        body: Some(reply.body),
        error: None,
        reason: None,
        detail: None,
        verb: Some(verb.as_str().to_string()),
    };
    signed_reply(&state.identity, &target.node_id, &caller.node_id, &mesh_reply)
}

fn signed_reply(
    identity: &Identity,
    target_node_id: &str,
    caller_node_id: &str,
    reply: &MeshReply,
) -> (u16, Vec<(String, String)>, String) {
    let body = reply.encode();
    let ts = wire::now_seconds();
    let signature = identity.sign(&MeshReply::reply_message(target_node_id, caller_node_id, ts, &body));
    (
        200,
        vec![("x-wa-ts".to_string(), ts.to_string()), ("x-wa-sig".to_string(), signature)],
        body,
    )
}

/// Record a request only after every other check passed, so a forgery cannot burn a real request's
/// id. The window is twice the freshness window, so a request cannot be replayed at its own edge.
fn is_replayed(state: &Arc<State>, from: &str, ts: u64, signature: &str, now_s: u64) -> bool {
    let key = format!("{from}|{ts}|{signature}");
    let Ok(mut seen) = state.seen.lock() else { return true };
    seen.retain(|_, at| now_s.saturating_sub(*at) < wire::REPLAY_WINDOW_SECONDS);
    if seen.contains_key(&key) {
        return true;
    }
    seen.insert(key, now_s);
    false
}
