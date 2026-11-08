//! One admission decision, on every path a peer can reach this node by.
//!
//! A mesh call is the same signed bytes whether it arrives on the direct listener (`POST /mesh/call`)
//! or is handed over by the relay (`POST /node/call` with the same envelope and headers). The relay is
//! transport only: it carries bytes it cannot read and its own rules never decide who may command
//! whom. So the *target* runs exactly one function over exactly one envelope, and this module is it.
//!
//! The three answers are deliberately different kinds of thing:
//!
//! * [`Admission::Allow`] — authenticated and authorized by this node's own verified roster and its
//!   `mesh` grants. The caller executes `call`, and the audit line is written when it finishes.
//! * [`Admission::Refuse`] — the answer, ready to send. A refusal after authentication is signed (a
//!   denial is a decision the caller must be able to tell from something the network said); a refusal
//!   before it carries one allow-listed code and nothing else.
//! * [`Admission::Legacy`] — the target has **no verified roster**, so the mesh cannot decide and
//!   today's path must: the operator-pin check of the node's binding (or its enrollment) decides who
//!   may call it. This is what keeps existing operators working, and it is the reason a node that has
//!   never had a roster pushed to it behaves exactly as it did yesterday.
//!
//! `WA_MESH=1` is the process switch. A node that has had a roster pushed to it *while it was running*
//! cannot change its own environment, so the operator's own `policy.json` carries the same statement
//! (`"mesh": {"enabled": true, …}`) and [`MeshPolicy::enabled`] is read per call: pushing a roster must
//! take effect without a restart, or the bootstrap could never verify itself.
use crate::audit::{Event, Sink};
use crate::hierarchy::{authorize, Verdict, Verb};
use crate::identity::Identity;
use crate::policy::MeshPolicy;
use crate::roster::Roster;
use crate::server::{Call, Reply};
use crate::wire::{self, MeshCall, MeshReply};
use serde_json::json;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Instant;

/// The header that says "this body is a mesh envelope, decide it by the roster".
pub const MESH_HEADER: &str = "x-wa-mesh";
/// The header a caller sets when the relay is carrying the call. The relay drops response headers, so
/// the answer has to carry its signature in the body; the target has to know which shape to send. Only
/// the *answer* depends on it — a caller that lies about its carrier only breaks its own verification.
pub const CARRIER_HEADER: &str = "x-wa-mesh-carrier";

/// Which carrier the caller says it used.
pub fn carrier(headers: &[(String, String)]) -> Transport {
    let relayed = headers.iter().any(|(key, value)| {
        key.eq_ignore_ascii_case(CARRIER_HEADER) && value.trim().eq_ignore_ascii_case("relay")
    });
    if relayed {
        Transport::Relay
    } else {
        Transport::Direct
    }
}

/// Where a mesh call came from, for the audit line only. Nothing is decided from it: a relayed call
/// and a direct one are admitted by the same code over the same bytes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Transport {
    Direct,
    Relay,
}

impl Transport {
    pub fn label(self) -> &'static str {
        match self {
            Transport::Direct => "direct",
            Transport::Relay => "relay",
        }
    }
}

/// One request as it arrived: its headers verbatim, its body verbatim, and how it got here.
pub struct Inbound {
    pub headers: Vec<(String, String)>,
    pub body: String,
    pub transport: Transport,
}

impl Inbound {
    pub fn direct(headers: Vec<(String, String)>, body: impl Into<String>) -> Inbound {
        Inbound { headers, body: body.into(), transport: Transport::Direct }
    }

    pub fn relayed(headers: Vec<(String, String)>, body: impl Into<String>) -> Inbound {
        Inbound { headers, body: body.into(), transport: Transport::Relay }
    }

    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(key, _)| key.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_str())
    }
}

/// Does this request claim to be a mesh call at all? A plain `/node/call` does not, and is never
/// touched by this module.
pub fn is_mesh(headers: &[(String, String)]) -> bool {
    headers
        .iter()
        .any(|(key, value)| key.eq_ignore_ascii_case(MESH_HEADER) && value.trim() == "1")
}

/// The caller's own `/node/call` request, carried opaquely inside the envelope. It is what today's
/// path understands, so it is what a legacy admission gets handed. The type is the client's, so the
/// two ends cannot drift.
pub use crate::client::Inner;

pub enum Admission {
    /// Authenticated and authorized. Run `call`, then [`Admitter::finish`] with the status.
    Allow(Box<Allowed>),
    /// The answer, ready to send.
    Refuse { status: u16, headers: Vec<(String, String)>, body: String },
    /// The mesh cannot decide here (no verified roster, or the flag and the policy are both off):
    /// today's admission applies. `body`/`headers` are the inner request when the envelope could be
    /// read, so an existing operator's call still reaches the pin check with the bytes it signed.
    Legacy { body: String, headers: Vec<(String, String)>, why: String },
}

pub struct Allowed {
    pub call: Call,
    pub verdict: Verdict,
    pub verb: Verb,
    pub transport: Transport,
    pub started: Instant,
    audit: Arc<dyn Sink>,
    levels: (u8, u8),
}

impl Allowed {
    /// One line, once the capability has run. No message text and no arguments, ever.
    pub fn finish(&self, reply: &Reply) {
        Event::new("recv", &self.call.from.node_id, &self.call.to.node_id)
            .levels(Some(self.levels.0), Some(self.levels.1))
            .verb(self.verb.as_str())
            .verdict("allow", self.verdict.reason)
            .transport(self.transport.label(), self.transport.label())
            .outcome(
                reply.status == 200,
                Some(reply.status),
                self.started.elapsed().as_millis() as u64,
                1,
            )
            .emit(self.audit.as_ref());
    }

    /// The signed reply of a call that was allowed but whose handler failed.
    pub fn failed(&self, code: &str) {
        Event::new("recv", &self.call.from.node_id, &self.call.to.node_id)
            .levels(Some(self.levels.0), Some(self.levels.1))
            .verb(self.verb.as_str())
            .verdict("deny", code)
            .transport(self.transport.label(), self.transport.label())
            .outcome(false, Some(500), self.started.elapsed().as_millis() as u64, 1)
            .emit(self.audit.as_ref());
    }
}

/// The one replay window this process has (see [`Admitter::is_replayed`]).
fn replay_window() -> &'static Mutex<HashMap<String, u64>> {
    static WINDOW: std::sync::OnceLock<Mutex<HashMap<String, u64>>> = std::sync::OnceLock::new();
    WINDOW.get_or_init(|| Mutex::new(HashMap::new()))
}

/// How many requests the replay window is holding, for a test that asserts a forged request did not
/// burn a real one.
pub fn replay_window_len() -> usize {
    replay_window().lock().map(|seen| seen.len()).unwrap_or(0)
}

/// Where a node's roster and its `mesh` policy come from. Asked once per decision, so a roster pushed
/// to a running node is in force on the next call and not on the next restart.
pub trait Source: Send + Sync {
    fn load(&self) -> Result<(Roster, MeshPolicy), String>;
}

/// The snapshot a caller already has in hand (the listener's own configuration, and every test).
pub struct FixedSource {
    pub roster: Roster,
    pub policy: MeshPolicy,
}

impl Source for FixedSource {
    fn load(&self) -> Result<(Roster, MeshPolicy), String> {
        Ok((self.roster.clone(), self.policy.clone()))
    }
}

/// The node's own files, the way the rest of the mesh resolves them.
pub struct NodeFiles {
    pub policy: PathBuf,
    pub roster: PathBuf,
    pub config: PathBuf,
}

impl Source for NodeFiles {
    fn load(&self) -> Result<(Roster, MeshPolicy), String> {
        let policy = MeshPolicy::from_policy_file(&self.policy).map_err(|error| error.0)?;
        let roster_path = policy.roster_path(&self.config).unwrap_or_else(|| self.roster.clone());
        let roster = Roster::from_file(&roster_path).map_err(|error| error.0)?;
        Ok((roster, policy))
    }
}

/// The switch for the *process*: `WA_MESH=1` (or `WASM_AGENT_MESH=1`).
pub fn flag_on() -> bool {
    matches!(std::env::var("WA_MESH").as_deref().map(str::trim), Ok("1"))
        || matches!(std::env::var("WASM_AGENT_MESH").as_deref().map(str::trim), Ok("1"))
}

/// Is the mesh in force on this node? The flag, or the operator's own statement in `policy.json`
/// (`mesh.enabled`), which is what a roster pushed to a running node writes — the same rule, and the
/// same precedence, as every other gate ([`crate::gate`]).
pub fn in_force(policy: &MeshPolicy) -> bool {
    crate::gate::decide(crate::gate::env_answer(), Some(policy)).enabled
}

/// The one place a mesh envelope is decided, for the direct listener, the relay hop and the Lua
/// admission alike.
pub struct Admitter {
    source: Arc<dyn Source>,
    identity: Identity,
    audit: Arc<dyn Sink>,
}

impl Admitter {
    pub fn new(source: Arc<dyn Source>, identity: Identity, audit: Arc<dyn Sink>) -> Admitter {
        Admitter { source, identity, audit }
    }

    pub fn from_files(paths: NodeFiles, identity: Identity, audit: Arc<dyn Sink>) -> Admitter {
        Admitter::new(Arc::new(paths), identity, audit)
    }

    pub fn identity(&self) -> &Identity {
        &self.identity
    }

    /// What this node's roster and policy are right now, for `/mesh/health`, `wa mesh status` and the
    /// bootstrap's own verification step.
    pub fn snapshot(&self) -> Result<(Roster, MeshPolicy), String> {
        self.source.load()
    }

    /// `(in force, status word)`: the status word is `verified`, or the reason the roster is not.
    pub fn status(&self) -> (bool, String) {
        match self.source.load() {
            Err(error) => (false, error),
            Ok((roster, policy)) => match roster.verify(&policy.roster_key, wire::now_seconds()) {
                Ok(()) => (in_force(&policy), "verified".to_string()),
                Err(error) => (false, error.0),
            },
        }
    }

    pub fn decide(&self, inbound: &Inbound) -> Admission {
        if !is_mesh(&inbound.headers) {
            return Admission::Legacy {
                body: inbound.body.clone(),
                headers: inbound.headers.clone(),
                why: "not_mesh".into(),
            };
        }
        let now_s = wire::now_seconds();
        let started = Instant::now();
        let (roster, policy) = match self.source.load() {
            Ok(snapshot) => snapshot,
            Err(error) => {
                // The envelope cannot be decided, so today's admission takes it: a missing roster is
                // "not a mesh node yet", which is exactly the pre-bootstrap state.
                return self.legacy(inbound, &format!("roster_unreadable:{error}"));
            }
        };
        // Whether this node is enabled at all (the process flag, or `mesh.enabled` in its own policy)
        // is the *route's* gate: the listener is only mounted when it is, and `host.mesh_call` answers
        // `mesh_disabled` before it gets here. What is left to decide is the roster.
        if let Err(error) = roster.verify(&policy.roster_key, now_s) {
            // No verified roster: the operator's pins are the authority, exactly as before.
            return self.legacy(inbound, &format!("roster_unverified:{}", error.0));
        }
        let unsigned = |status: u16, code: &str| Admission::Refuse {
            status,
            headers: Vec::new(),
            body: json!({"error": code}).to_string(),
        };
        let call = match MeshCall::parse(&inbound.body) {
            Ok(call) => call,
            Err(_) => return unsigned(400, "bad_request"),
        };
        let header_node = inbound.header("x-wa-node").unwrap_or_default();
        if header_node != call.from_node_id {
            return unsigned(400, "bad_request");
        }
        let Some(caller) = roster.node(&call.from_node_id).cloned() else {
            return unsigned(403, "unknown_caller");
        };
        let header_key = inbound.header("x-wa-pub").unwrap_or_default();
        if header_key != caller.public_key {
            return unsigned(401, "bad_signature");
        }
        let ts = match inbound.header("x-wa-ts").and_then(|value| value.parse::<u64>().ok()) {
            Some(ts) => ts,
            None => return unsigned(400, "bad_request"),
        };
        let signature = inbound.header("x-wa-sig").unwrap_or_default();
        if !crate::identity::verify(
            &caller.public_key,
            &MeshCall::call_message(&call.from_node_id, ts, &inbound.body),
            signature,
        ) {
            return unsigned(401, "bad_signature");
        }
        if !wire::is_fresh(ts, now_s) {
            return unsigned(408, "stale_request");
        }
        if self.is_replayed(&caller.node_id, ts, signature, now_s) {
            return unsigned(409, "replayed_request");
        }
        if call.to_node_id != self.identity.node_id {
            return unsigned(403, "wrong_target");
        }
        let Some(target) = roster.node(&self.identity.node_id).cloned() else {
            return unsigned(503, "handler_unavailable");
        };
        let verb = Verb::from_capability(&call.capability);
        let verdict = authorize(&policy, &caller, &target, verb, now_s);
        if !verdict.is_allow() {
            Event::new("recv", &caller.node_id, &target.node_id)
                .levels(Some(caller.level), Some(target.level))
                .verb(verb.as_str())
                .verdict("deny", verdict.reason)
                .transport(inbound.transport.label(), inbound.transport.label())
                .outcome(false, Some(403), started.elapsed().as_millis() as u64, 1)
                .emit(self.audit.as_ref());
            let reply = MeshReply::refusal(
                &call.request_id,
                &target.node_id,
                "mesh_denied",
                verdict.reason,
                &verdict.detail,
                verb.as_str(),
            );
            return match inbound.transport {
                Transport::Direct => {
                    let (status, headers, body) =
                        seal_reply(&self.identity, &target.node_id, &caller.node_id, &reply);
                    Admission::Refuse { status, headers, body }
                }
                // The relay drops headers, so the reply carries its own signature inside the body.
                Transport::Relay => Admission::Refuse {
                    status: 200,
                    headers: Vec::new(),
                    body: crate::relay::RelayAnswer::seal(
                        &self.identity,
                        &target.node_id,
                        &caller.node_id,
                        &reply,
                    )
                    .encode(),
                },
            };
        }
        let call = Call {
            from: caller.clone(),
            to: target.clone(),
            verb,
            capability: call.capability.clone(),
            args: call.args.clone(),
            request_id: call.request_id.clone(),
            inner: Inner { body: call.inner_body.clone(), headers: call.inner_headers.clone() },
        };
        Admission::Allow(Box::new(Allowed {
            call,
            verdict,
            verb,
            transport: inbound.transport,
            started,
            audit: self.audit.clone(),
            levels: (caller.level, target.level),
        }))
    }

    /// Today's path, with the caller's own request when the envelope could be read: the pin check
    /// inside `wa_node_call` then decides exactly as it does today.
    fn legacy(&self, inbound: &Inbound, why: &str) -> Admission {
        let outer = MeshCall::parse(&inbound.body).ok();
        let (body, headers, why) = match outer {
            Some(call) => (
                call.inner_body.clone(),
                call.inner_headers.clone(),
                format!("{why}:legacy_pins"),
            ),
            None => (inbound.body.clone(), inbound.headers.clone(), why.to_string()),
        };
        Event::new("recv", "peer", &self.identity.node_id)
            .verdict("deny", &why)
            .transport(inbound.transport.label(), inbound.transport.label())
            .emit(self.audit.as_ref());
        Admission::Legacy { body, headers, why }
    }

    /// Record a request only after every other check passed, so a forgery cannot burn a real request's
    /// id. The window is twice the freshness window, so a request cannot be replayed at its own edge.
    ///
    /// The window is **per process**, not per [`Admitter`]: one node is one process, and the listener,
    /// the relay hop and the node's own Lua admission must share it — otherwise the same signed bytes
    /// could be spent once on each path, which is exactly what a replay is.
    fn is_replayed(&self, from: &str, ts: u64, signature: &str, now_s: u64) -> bool {
        let key = format!("{from}|{ts}|{signature}");
        let Ok(mut seen) = replay_window().lock() else { return true };
        seen.retain(|_, at| now_s.saturating_sub(*at) < wire::REPLAY_WINDOW_SECONDS);
        if seen.contains_key(&key) {
            return true;
        }
        seen.insert(key, now_s);
        false
    }
}

/// The signed answer to an allowed (or authenticated-and-refused) call, as the direct listener sends
/// it: the envelope in the body, its signature in the headers.
pub fn seal_reply(
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

/// One-shot tickets for the local execution hop.
///
/// The direct listener authenticates and authorizes a call, then hands it to this process's own
/// `/node/admitted` route so a node-thread can run it. The hop must prove *which* decision it is
/// carrying: a ticket is minted here by the listener, is unguessable, names the caller and the
/// capability it admits, is single-use and expires in seconds. A peer on the network cannot mint one,
/// so the local route cannot be used to skip the roster.
pub mod tickets {
    use super::*;
    use std::sync::OnceLock;
    use std::time::Duration;

    /// How long a minted ticket may sit before it is refused: longer than any local hop, far shorter
    /// than anything an operator would notice.
    pub const TICKET_TTL: Duration = Duration::from_secs(30);

    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct Ticket {
        pub id: String,
        pub caller_node_id: String,
        pub caller_public_key: String,
        pub capability: String,
        /// The verb the roster and the grants decided on, so the local hop does not have to guess it
        /// (and cannot widen it: the attestation it carries is bound to this verb).
        pub verb: String,
        pub request_id: String,
        /// The node-signed attestation `wa_node_call` admits this call by, in its JSON form. Empty
        /// means "no attestation": the local admission then falls back to the legacy capability list.
        pub attestation: String,
        /// Unix milliseconds after which the ticket is refused even if it was never spent.
        pub expires_at_ms: u64,
    }

    fn registry() -> &'static Mutex<HashMap<String, Ticket>> {
        static REGISTRY: OnceLock<Mutex<HashMap<String, Ticket>>> = OnceLock::new();
        REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
    }

    fn next_id() -> String {
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let counter = COUNTER.fetch_add(1, Ordering::Relaxed);
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|duration| duration.as_nanos())
            .unwrap_or(0);
        format!("{nanos:x}-{:x}-{counter:x}", std::process::id())
    }

    /// Mint a ticket for one admitted call. Called by the listener's handler, in this process.
    pub fn mint(allowed: &Allowed) -> Ticket {
        mint_for(
            &allowed.call.from.node_id,
            &allowed.call.from.public_key,
            &allowed.call.capability,
            allowed.verb.as_str(),
            &allowed.call.request_id,
            "",
        )
    }

    /// The same, for a caller that holds the facts and not the whole admission. `attestation` is the
    /// node-signed proof `wa_node_call` admits by verb ([`crate::attest`]); an empty one is a ticket
    /// that admits nothing new.
    pub fn mint_for(
        caller_node_id: &str,
        caller_public_key: &str,
        capability: &str,
        verb: &str,
        request_id: &str,
        attestation: &str,
    ) -> Ticket {
        let now_ms = wire::now_millis();
        let ticket = Ticket {
            id: next_id(),
            caller_node_id: caller_node_id.to_string(),
            caller_public_key: caller_public_key.to_string(),
            capability: capability.to_string(),
            verb: verb.to_string(),
            request_id: request_id.to_string(),
            attestation: attestation.to_string(),
            expires_at_ms: now_ms.saturating_add(TICKET_TTL.as_millis() as u64),
        };
        if let Ok(mut registry) = registry().lock() {
            registry.retain(|_, held| held.expires_at_ms > now_ms);
            registry.insert(ticket.id.clone(), ticket.clone());
        }
        ticket
    }

    /// Spend a ticket. `None` for anything unknown, expired or already used — and the entry is removed
    /// either way, so a ticket cannot be spent twice by a retry loop.
    pub fn take(id: &str) -> Option<Ticket> {
        let mut registry = registry().lock().ok()?;
        let ticket = registry.remove(id)?;
        if ticket.expires_at_ms <= wire::now_millis() {
            return None;
        }
        Some(ticket)
    }

    pub fn live() -> usize {
        registry().lock().map(|registry| registry.len()).unwrap_or(0)
    }

    pub fn clear() {
        if let Ok(mut registry) = registry().lock() {
            registry.clear();
        }
    }
}

/// Resolve a roster path the way the policy says: absolute, or relative to the config directory.
pub fn resolve_roster(policy: &MeshPolicy, config: &Path, default: &Path) -> PathBuf {
    policy.roster_path(config).unwrap_or_else(|| default.to_path_buf())
}

/// The audit sink for a node's own files, shared by the listener and the relay hop: one file, one
/// stderr, so an operator reading `mesh.jsonl` sees every path in the order they happened.
pub fn file_audit(paths: &crate::host_call::Paths) -> Arc<dyn Sink> {
    crate::host_call::audit_sink(paths)
}

