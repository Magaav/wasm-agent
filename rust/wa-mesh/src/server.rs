//! The direct transport, listener side: `/mesh/health` and `/mesh/call`.
//!
//! The listener does the same checks the caller made — and the same checks the relay-delivered route
//! makes — because both go through [`crate::admission`]: who is this, may they, and is this really for
//! me, against *this* node's roster and `policy.json`, never against the caller's claim. Only then does
//! it hand the call to the [`Handler`], which is the node's business: this crate knows how to authorize
//! a call, not how to run a capability.
//!
//! Refusals before authentication are unsigned (they cannot be signed: a reply signature binds an
//! answer to a verified request) and carry one allow-listed code. Once the caller is authenticated,
//! every answer is signed, including a denial — a denial from the target is a decision, and the
//! caller should be able to tell it apart from something the network said.
//!
//! The roster and the policy are read per call from the configured [`Source`], so a roster installed
//! by `wa fleet push-roster` is in force on the next call and not on the next restart. The snapshot
//! constructor (`ServerConfig::new`) still takes one roster and one policy, which is what every test
//! and the first deployment use.
use crate::admission::{self, Admission, Admitter, Inbound};
use crate::audit::Sink;
use crate::hierarchy::Verb;
use crate::http;
use crate::identity::Identity;
use crate::policy::MeshPolicy;
use crate::roster::{Roster, RosterNode};
use crate::wire::{self, MeshReply};
use serde_json::{json, Value};
use std::io::Write;
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

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
    pub source: Arc<dyn admission::Source>,
    pub handler: Arc<dyn Handler>,
    pub audit: Arc<dyn Sink>,
    pub max_body: usize,
    pub io_timeout: Duration,
    pub max_connections: usize,
}

impl ServerConfig {
    /// A listener over one roster and one policy — the snapshot every test uses.
    pub fn new(bind: impl Into<String>, identity: Identity, roster: Roster, policy: MeshPolicy, handler: Arc<dyn Handler>, audit: Arc<dyn Sink>) -> ServerConfig {
        ServerConfig::with_source(
            bind,
            identity,
            Arc::new(admission::FixedSource { roster, policy }),
            handler,
            audit,
        )
    }

    /// The same listener over a source asked per call (the node's own files, so a pushed roster lands).
    pub fn with_source(bind: impl Into<String>, identity: Identity, source: Arc<dyn admission::Source>, handler: Arc<dyn Handler>, audit: Arc<dyn Sink>) -> ServerConfig {
        ServerConfig {
            bind: bind.into(),
            identity,
            source,
            handler,
            audit,
            max_body: http::MAX_BODY,
            io_timeout: Duration::from_secs(30),
            max_connections: 32,
        }
    }
}

struct State {
    admitter: Admitter,
    handler: Arc<dyn Handler>,
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

/// How long the accept loop sleeps between checks of the stop flag.
///
/// `TcpListener` has no accept timeout and the standard library exposes no way to wait on a socket
/// *or* a flag, so the loop used to block in `accept()` and `Drop` woke it with a throwaway
/// connection. That wake is a socket op without a usable deadline: when the throwaway connect did
/// not complete (a loopback handshake can time out on a loaded machine, and the result was ignored)
/// the loop stayed in `accept()` and `Drop` blocked in `join()` **forever, at zero CPU** — which is
/// how one end-to-end test hung for twenty minutes under `cargo test --workspace`. Polling makes the
/// stop flag the only thing that ends the loop, so `drop` is bounded by one poll interval and no
/// socket op on the shutdown path can stall.
const ACCEPT_POLL: Duration = Duration::from_millis(5);

impl Server {
    pub fn start(config: ServerConfig) -> Result<Server, String> {
        let listener = TcpListener::bind(config.bind.as_str())
            .map_err(|error| format!("bind {} failed: {error}", config.bind))?;
        let addr = listener.local_addr().map_err(|error| error.to_string())?;
        let state = Arc::new(State {
            admitter: Admitter::new(config.source, config.identity, config.audit),
            handler: config.handler,
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
            // The accept loop polls `stop` every `ACCEPT_POLL` (see there): no wake connection, so a
            // failed connect on a loaded machine cannot turn this join into a permanent block.
            let _ = join.join();
        }
    }
}

fn accept_loop(listener: TcpListener, state: Arc<State>, stop: Arc<AtomicBool>) {
    if listener.set_nonblocking(true).is_err() {
        return;
    }
    while !stop.load(Ordering::SeqCst) {
        let stream = match listener.accept() {
            Ok((stream, _)) => stream,
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(ACCEPT_POLL);
                continue;
            }
            // A listener error that is not `WouldBlock` (a peer that vanished, a momentary resource
            // shortage) is not a reason to stop listening; sleep so a persistent one cannot spin.
            Err(_) => {
                std::thread::sleep(ACCEPT_POLL);
                continue;
            }
        };
        // The bound listener is non-blocking; an accepted stream must not inherit that, or a peer's
        // short read would look like end-of-file instead of waiting `io_timeout` for the rest.
        if stream.set_nonblocking(false).is_err() {
            continue;
        }
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
    let identity = state.admitter.identity();
    let (in_force, status) = state.admitter.status();
    let snapshot = state.admitter.snapshot();
    let (roster, policy) = match &snapshot {
        Ok((roster, policy)) => (Some(roster.clone()), Some(policy.clone())),
        Err(_) => (None, None),
    };
    let me = roster
        .as_ref()
        .and_then(|roster| roster.node(&identity.node_id))
        .cloned();
    json!({
        "mesh": wire::SCHEMA,
        "node_id": identity.node_id,
        "public_key": identity.public_key,
        "name": me.as_ref().map(|node| node.name.clone()).unwrap_or_default(),
        "level": me.as_ref().map(|node| node.level),
        "fleet": roster.as_ref().map(|roster| roster.fleet.clone()).unwrap_or_default(),
        "roster_fingerprint": roster.as_ref().map(|roster| roster.fingerprint()).unwrap_or_default(),
        "roster_verified": status == "verified",
        "roster_status": status,
        "in_force": in_force,
        "grants": policy.as_ref().map(|policy| policy.grants.len()).unwrap_or(0),
        "unsigned": "this answer names a node, it does not authenticate one",
    })
}

fn call(state: &Arc<State>, request: &http::Request) -> (u16, Vec<(String, String)>, String) {
    // A listener with no verified roster refuses every call rather than trusting the caller's copy of
    // it — the same answer this node gave before the relay could carry a mesh call.
    // The listener exists only because somebody mounted it (`WA_MESH=1` + a port, or the tests), so it
    // does not re-ask whether the *process* is enabled — only whether the roster it holds verifies.
    let (_, status) = state.admitter.status();
    if status != "verified" {
        return (503, Vec::new(), json!({"error": "roster_unverified", "reason": status}).to_string());
    }
    if !admission::is_mesh(&request.headers) {
        return (400, Vec::new(), json!({"error": "not_mesh"}).to_string());
    }
    match state.admitter.decide(&Inbound::direct(request.headers.clone(), request.body_text())) {
        Admission::Allow(allowed) => {
            let handled = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                state.handler.handle(&allowed.call)
            }));
            let reply = match handled {
                Ok(reply) => reply,
                Err(_) => {
                    allowed.failed("handler_failed");
                    return (500, Vec::new(), json!({"error": "internal_error"}).to_string());
                }
            };
            allowed.finish(&reply);
            let mesh_reply = MeshReply {
                schema: wire::SCHEMA,
                request_id: allowed.call.request_id.clone(),
                from_node_id: allowed.call.to.node_id.clone(),
                ok: true,
                status: Some(reply.status),
                body: Some(reply.body),
                error: None,
                reason: None,
                detail: None,
                verb: Some(allowed.verb.as_str().to_string()),
            };
            admission::seal_reply(
                state.admitter.identity(),
                &allowed.call.to.node_id,
                &allowed.call.from.node_id,
                &mesh_reply,
            )
        }
        Admission::Refuse { status, headers, body } => (status, headers, body),
        Admission::Legacy { why, .. } => {
            (503, Vec::new(), json!({"error": "roster_unverified", "reason": why}).to_string())
        }
    }
}
