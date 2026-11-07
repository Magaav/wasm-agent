//! Wiring the crate into a node: the listener mount and `host.mesh_call`.
//!
//! Everything here is behind `WA_MESH=1` (`WASM_AGENT_MESH=1` is read too), or behind the operator's own
//! `mesh.enabled` statement in `policy.json` — which is what `wa fleet push-roster` writes, so a roster
//! installed on a *running* node takes effect on the next call. With neither, the node never binds the
//! listener and `host.mesh_call` answers `mesh_disabled` **without touching the network or the disk** —
//! which is what makes "with the flag unset, behaviour is byte-for-byte unchanged" a property of the
//! code rather than a promise in a document.
//!
//! Request modes of `host.mesh_call` (one capability, so the catalogue does not grow for a feature
//! only a fleet member ever uses):
//!
//! | request | answer | who uses it |
//! | --- | --- | --- |
//! | `{node, capability, args, inner_body, inner_headers, peers?}` | the call, or its refusal | `wa call`, `nodes.remote_call` |
//! | `{node, capability, dry_run: true}` | the verdict only, no network | an operator, and a test |
//! | `{admit: {headers, body, transport}}` | the roster's decision on an *inbound* envelope | the node's own admission (Lua), so pins are not the authority when a roster is |
//! | `{seal: {reply, caller}}` | the signed answer to send back | the same, for a relayed answer |
//! | `{verify_roster: {text, key}}` | whether a roster verifies against a key | `wa fleet push-roster` (never behind the flag) |
//! | `{roster_plan: {…}}` | what a push would change | `wa fleet push-roster --dry-run` |
//! | `{install_roster: {…}}` | what a push changed | the target of `wa fleet push-roster` |
//!
//! Paths, in the order the rest of the node resolves them:
//!
//! | what | environment | default |
//! | --- | --- | --- |
//! | node key | `WASM_AGENT_NODE_KEY` | `<home>/.wasm-agent/node.key` |
//! | policy (the `mesh` section) | `WA_GRANT_POLICY` | `<home>/.wasm-agent/policy.json` |
//! | roster | `WASM_AGENT_MESH_ROSTER`, else `mesh.roster` | `<config>/mesh-roster.json` |
//! | peer cache | `WASM_AGENT_MESH_CACHE` | `<state>/mesh/peers.json` |
//! | audit trail | — | `<state>/audit/mesh.jsonl` |
//! | relay (fallback carrier) | `WASM_AGENT_RELAY`, else the binding's service | — |
//! | listener port | `WASM_AGENT_MESH_PORT` | none: a flag alone never opens a port |
//! | listener address | `WASM_AGENT_MESH_BIND` | `127.0.0.1` |
use crate::admission::{self, Admission, Admitter, Inbound};
use crate::audit::{FileSink, Sink, StderrSink, Tee};
use crate::cache::PeerCache;
use crate::client::{Client, ClientConfig, Inner};
use crate::hierarchy::Verdict;
use crate::http;
use crate::identity::Identity;
use crate::policy::MeshPolicy;
use crate::relay;
use crate::roster::Roster;
use crate::server::{Call, Handler, Reply, Server, ServerConfig};
use crate::wire;
use serde_json::{json, Value};
use std::ffi::c_int;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use wa_host_support::json::push_json;
use wa_host_support::lua::{arg_string, LuaState};

pub const AUDIT_LIMIT_BYTES: u64 = 8 * 1024 * 1024;

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().map(|value| value.trim().to_string()).filter(|value| !value.is_empty())
}

/// Is the feature on for this process? `WA_MESH=1`, or `WASM_AGENT_MESH=1`.
pub fn enabled() -> bool {
    admission::flag_on()
}

/// Is it on for this node, process flag or the operator's own `policy.json` statement?
pub fn enabled_here(policy: &MeshPolicy) -> bool {
    admission::in_force(policy)
}

/// Does this node's own policy enable the mesh? Read only when the process flag is off, and only to
/// answer that question: nothing is written, and no network is touched.
fn policy_enabled() -> bool {
    MeshPolicy::from_policy_file(&Paths::resolve().policy)
        .map(|policy| policy.enabled)
        .unwrap_or(false)
}

/// Where this node keeps the mesh's files. One resolution, so the host capability and the mount
/// cannot disagree about which roster they read.
pub struct Paths {
    pub key: PathBuf,
    pub policy: PathBuf,
    pub config: PathBuf,
    pub roster: PathBuf,
    pub cache: PathBuf,
    pub audit: PathBuf,
}

impl Paths {
    pub fn resolve() -> Paths {
        let home = PathBuf::from(wa_host_support::paths::resolve_home());
        let config = home.join(".wasm-agent");
        let key = crate::identity::default_key_path();
        let policy = env("WA_GRANT_POLICY")
            .map(PathBuf::from)
            .unwrap_or_else(|| config.join("policy.json"));
        let roster = env("WASM_AGENT_MESH_ROSTER")
            .map(PathBuf::from)
            .unwrap_or_else(|| config.join("mesh-roster.json"));
        let cache = env("WASM_AGENT_MESH_CACHE")
            .map(PathBuf::from)
            .unwrap_or_else(|| config.join("mesh").join("peers.json"));
        let audit = config.join("audit").join("mesh.jsonl");
        Paths { key, policy, config, roster, cache, audit }
    }

    /// The roster path once `policy.json` has had its say: an explicit environment variable wins, then
    /// `mesh.roster` (relative paths are relative to the config directory), then the default.
    pub fn with_policy(mut self, policy: &MeshPolicy) -> Paths {
        if env("WASM_AGENT_MESH_ROSTER").is_none() {
            if let Some(configured) = &policy.roster {
                let configured = PathBuf::from(configured);
                self.roster = if configured.is_absolute() {
                    configured
                } else {
                    self.config.join(configured)
                };
            }
        }
        self
    }
}

/// The sinks a node's mesh writes to: stderr always, and its own audit file when one can be opened.
pub fn audit_sink(paths: &Paths) -> Arc<dyn Sink> {
    Arc::new(Tee::new(vec![
        Box::new(StderrSink),
        Box::new(FileSink::new(paths.audit.clone(), AUDIT_LIMIT_BYTES)),
    ]))
}

fn unavailable(reason: &str, detail: impl Into<String>) -> Value {
    json!({"ok": false, "error": "mesh_unavailable", "reason": reason, "detail": detail.into(), "fallback": null})
}

fn disabled() -> Value {
    json!({"ok": false, "error": "mesh_disabled", "fallback": null})
}

/// `host.mesh_call(request_json) -> json`
///
/// The request is `{node, capability, args, inner_body, inner_headers, peers?, timeout_seconds?}`:
/// `node` is a node id or a roster name, `peers` is the `/nodes` answer the node already has (this is
/// the discovery half — the rendezvous is asked by the node, never by the call), and `inner_body` /
/// `inner_headers` are the ordinary `/node/call` request the caller built so the target can run it.
pub fn dispatch(request: &Value) -> Value {
    // The bootstrap modes first, and *not* behind the switch: `wa fleet push-roster` is how a node that
    // has never had the mesh is given it, so the command that carries the roster cannot require the
    // feature it is installing. `verify_roster` and `roster_plan` read; `install_roster` writes the
    // node's own files, and it is only reachable from a caller this node already admits under today's
    // operator pins (the `roster` capability, `lua/core/binding.lua`).
    if let Some(verify) = request.get("verify_roster") {
        return verify_roster(verify);
    }
    if let Some(plan) = request.get("roster_plan") {
        return roster_plan(plan);
    }
    if let Some(install) = request.get("install_roster") {
        return install_roster(install);
    }
    // Everything else — calling, admitting an inbound envelope, sealing an answer — is the feature
    // itself: the process flag, or the operator's own statement in `policy.json` (`mesh.enabled`),
    // which is what a roster pushed to a *running* node writes. The environment of a live process
    // cannot change, and a bootstrap that needed a restart could not verify itself.
    if !enabled() && !policy_enabled() {
        return disabled();
    }
    if let Some(inbound) = request.get("admit") {
        return admit_inbound(inbound);
    }
    if let Some(seal) = request.get("seal") {
        return seal_reply(seal);
    }
    let started = wire::now_millis();
    let paths = Paths::resolve();
    let policy = match MeshPolicy::from_policy_file(&paths.policy) {
        Ok(policy) => policy,
        Err(error) => return unavailable("policy_unreadable", error.0),
    };
    let paths = paths.with_policy(&policy);
    let roster = match Roster::from_file(&paths.roster) {
        Ok(roster) => roster,
        Err(error) => return unavailable("roster_unreadable", error.0),
    };
    let now_s = wire::now_seconds();
    if let Err(error) = roster.verify(&policy.roster_key, now_s) {
        return unavailable("roster_unverified", error.0);
    }
    let identity = match Identity::load(&paths.key) {
        Ok(identity) => identity,
        Err(error) => return unavailable("identity_unavailable", error),
    };
    let audit = audit_sink(&paths);
    let mut cache = match PeerCache::from_file(&paths.cache) {
        Ok(cache) => cache,
        Err(error) => {
            eprintln!("[mesh] peer cache unreadable, carrying on with the roster: {error}");
            PeerCache::empty()
        }
    };
    let now_ms = wire::now_millis();
    cache.merge_roster(&roster, now_ms);
    if let Some(peers) = request.get("peers") {
        cache.merge_rendezvous(peers, now_ms);
    }
    let selector = request.get("node").and_then(Value::as_str).unwrap_or_default();
    let capability = request.get("capability").and_then(Value::as_str).unwrap_or_default();
    if selector.is_empty() || capability.is_empty() {
        return json!({"ok": false, "error": "mesh_bad_request", "detail": "node and capability are required", "fallback": null});
    }
    let args = request.get("args").cloned().unwrap_or_else(|| json!({}));
    let inner = Inner {
        body: request.get("inner_body").and_then(Value::as_str).unwrap_or_default().to_string(),
        headers: inner_headers(request),
    };
    let config = ClientConfig {
        io_timeout: Duration::from_secs(
            request
                .get("timeout_seconds")
                .and_then(Value::as_u64)
                .unwrap_or(60)
                .clamp(5, 600),
        ),
        relay: relay::configured(&paths.config),
        ..ClientConfig::default()
    };
    let mut client = Client {
        identity: &identity,
        roster: &roster,
        policy: &policy,
        cache: &mut cache,
        audit: audit.as_ref(),
        config,
    };
    let outcome = client.call(selector, capability, args, inner);
    if let Err(error) = cache.save(&paths.cache, now_ms) {
        eprintln!("[mesh] peer cache not saved: {error}");
    }
    let mut answer = outcome.to_json();
    if let Some(object) = answer.as_object_mut() {
        object.insert("ms".into(), json!(wire::now_millis().saturating_sub(started)));
    }
    answer
}

fn inner_headers(request: &Value) -> Vec<(String, String)> {
    let Some(entries) = request.get("inner_headers").and_then(Value::as_array) else {
        return Vec::new();
    };
    entries
        .iter()
        .filter_map(|entry| {
            let pair = entry.as_array()?;
            let name = pair.first()?.as_str()?;
            let value = pair.get(1)?.as_str()?;
            Some((name.to_string(), value.to_string()))
        })
        .collect()
}

/// A node's mesh admitter over its own files: the roster and the policy are read per decision, so a
/// roster pushed to a running node is in force on the next call.
fn node_admitter(paths: &Paths) -> Result<Admitter, String> {
    let identity = Identity::load(&paths.key)?;
    Ok(Admitter::from_files(
        admission::NodeFiles {
            policy: paths.policy.clone(),
            roster: paths.roster.clone(),
            config: paths.config.clone(),
        },
        identity,
        audit_sink(paths),
    ))
}

fn header_pairs(value: &Value) -> Vec<(String, String)> {
    let Some(entries) = value.as_array() else { return Vec::new() };
    entries
        .iter()
        .filter_map(|entry| {
            let pair = entry.as_array()?;
            Some((pair.first()?.as_str()?.to_string(), pair.get(1)?.as_str()?.to_string()))
        })
        .collect()
}

fn pairs_json(headers: &[(String, String)]) -> Value {
    Value::Array(
        headers
            .iter()
            .map(|(name, value)| json!([name, value]))
            .collect(),
    )
}

/// `{admit: {headers, body, transport}}`: what this node's roster says about one inbound envelope.
///
/// This is the node's own admission in Lua (a bound node's relay runtime lives there), so that a
/// relayed mesh call is decided by the same function the direct listener uses — and so a target with a
/// verified roster never falls back to the operator pins.
fn admit_inbound(request: &Value) -> Value {
    let paths = Paths::resolve();
    let admitter = match node_admitter(&paths) {
        Ok(admitter) => admitter,
        Err(error) => return unavailable("identity_unavailable", error),
    };
    let headers = header_pairs(request.get("headers").unwrap_or(&Value::Null));
    let body = request.get("body").and_then(Value::as_str).unwrap_or_default();
    let relayed = request.get("transport").and_then(Value::as_str) == Some("relay");
    let inbound = if relayed { Inbound::relayed(headers, body) } else { Inbound::direct(headers, body) };
    match admitter.decide(&inbound) {
        Admission::Allow(allowed) => json!({
            "ok": true,
            "transport": allowed.transport.label(),
            "caller_node_id": allowed.call.from.node_id,
            "caller_public_key": allowed.call.from.public_key,
            "caller_name": allowed.call.from.name,
            "caller_level": allowed.call.from.level,
            "target_level": allowed.call.to.level,
            "capability": allowed.call.capability,
            "request_id": allowed.call.request_id,
            "verb": allowed.verb.as_str(),
            "decision": allowed.verdict.decision(),
            "reason": allowed.verdict.reason,
            "inner_body": allowed.call.inner.body,
            "inner_headers": pairs_json(&allowed.call.inner.headers),
        }),
        Admission::Refuse { status, headers, body } => json!({
            "ok": false,
            "error": "mesh_refused",
            "verified": status == 200,
            "status": status,
            "answer": body,
            "answer_headers": pairs_json(&headers),
            "legacy": false,
        }),
        Admission::Legacy { body, headers, why } => json!({
            "ok": false,
            "error": "mesh_legacy",
            "reason": why,
            "legacy": true,
            "inner_body": body,
            "inner_headers": pairs_json(&headers),
        }),
    }
}

/// `{seal: {reply, caller, transport}}`: the signed answer to an admitted call, in the shape its
/// carrier can deliver. A relayed answer carries the signature inside the body, because the relay
/// drops headers; a direct one keeps it in `x-wa-sig`.
fn seal_reply(request: &Value) -> Value {
    let paths = Paths::resolve();
    let identity = match Identity::load(&paths.key) {
        Ok(identity) => identity,
        Err(error) => return unavailable("identity_unavailable", error),
    };
    let text = request.get("reply").and_then(Value::as_str).unwrap_or_default();
    let caller = request.get("caller").and_then(Value::as_str).unwrap_or_default();
    let relayed = request.get("transport").and_then(Value::as_str) == Some("relay");
    let reply = match wire::MeshReply::parse(text) {
        Ok(reply) => reply,
        Err(error) => return json!({"ok": false, "error": "mesh_bad_request", "detail": error}),
    };
    if relayed {
        let answer = relay::RelayAnswer::seal(&identity, &identity.node_id, caller, &reply);
        json!({"ok": true, "body": answer.encode(), "headers": []})
    } else {
        let (_, headers, body) = admission::seal_reply(&identity, &identity.node_id, caller, &reply);
        json!({"ok": true, "body": body, "headers": pairs_json(&headers)})
    }
}

/// `{verify_roster: {text, key}}`: does this roster verify against this fleet key? The one check a push
/// must pass *before* it touches anything, done by the same verifier every node uses.
fn verify_roster(request: &Value) -> Value {
    let text = request.get("text").and_then(Value::as_str).unwrap_or_default();
    let key = request.get("key").and_then(Value::as_str).unwrap_or_default();
    let roster = match Roster::parse(text) {
        Ok(roster) => roster,
        Err(error) => return json!({"ok": false, "error": "roster_unverified", "detail": error.0}),
    };
    match roster.verify(key, wire::now_seconds()) {
        Ok(()) => json!({
            "ok": true,
            "fleet": roster.fleet,
            "fingerprint": roster.fingerprint(),
            "nodes": roster.nodes.len(),
            "entries": roster.names(),
            "issued_at": roster.issued_at,
            "expires_at": roster.expires_at,
        }),
        Err(error) => json!({"ok": false, "error": "roster_unverified", "detail": error.0}),
    }
}

fn push_request(request: &Value) -> crate::fleet::PushRequest {
    let field = |name: &str| request.get(name).and_then(Value::as_str).unwrap_or_default().to_string();
    crate::fleet::PushRequest {
        config: field("config"),
        roster: request.get("roster").and_then(Value::as_str).unwrap_or_default().to_string(),
        roster_key: field("roster_key"),
        caller_node_id: field("caller_node_id"),
        caller_public_key: field("caller_public_key"),
        target_node_id: field("target_node_id"),
        replace_key_signature: request
            .get("replace_key_signature")
            .and_then(Value::as_str)
            .map(str::to_string),
    }
}

/// `{roster_plan: {…}}`: what a push would do, with nothing written.
fn roster_plan(request: &Value) -> Value {
        let push = push_request(request);
    let roster = match Roster::parse(&push.roster) {
        Ok(roster) => roster,
        Err(error) => return json!({"ok": false, "error": "roster_unverified", "detail": error.0}),
    };
    crate::fleet::plan(std::path::Path::new(push.config.trim()), &roster, &push.roster_key)
}

/// `{install_roster: {…}}`: install the roster on this node — only after the caller has been admitted
/// by today's rules, which is the caller's (Lua's) job, not this function's.
fn install_roster(request: &Value) -> Value {
    push_request(request).install()
}

/// The verdict a caller would get, without calling: `host.mesh_call` with `"dry_run": true` answers
/// this and nothing else. It exists so an operator can see the hierarchy's answer before a call, and
/// so a test can ask the same function the client asks.
pub fn dry_run(request: &Value) -> Value {
    if !enabled() {
        return disabled();
    }
    let paths = Paths::resolve();
    let policy = match MeshPolicy::from_policy_file(&paths.policy) {
        Ok(policy) => policy,
        Err(error) => return unavailable("policy_unreadable", error.0),
    };
    let paths = paths.with_policy(&policy);
    let roster = match Roster::from_file(&paths.roster) {
        Ok(roster) => roster,
        Err(error) => return unavailable("roster_unreadable", error.0),
    };
    if let Err(error) = roster.verify(&policy.roster_key, wire::now_seconds()) {
        return unavailable("roster_unverified", error.0);
    }
    let identity = match Identity::load(&paths.key) {
        Ok(identity) => identity,
        Err(error) => return unavailable("identity_unavailable", error),
    };
    let Some(caller) = roster.node(&identity.node_id).cloned() else {
        return unavailable("self_not_in_roster", "this node is not in the fleet roster");
    };
    let selector = request.get("node").and_then(Value::as_str).unwrap_or_default();
    let capability = request.get("capability").and_then(Value::as_str).unwrap_or_default();
    let Some(target) = roster.node(selector).cloned() else {
        return json!({"ok": false, "error": "mesh_unknown_node", "node": selector, "fallback": null});
    };
    let verb = crate::hierarchy::Verb::from_capability(capability);
    let verdict: Verdict = crate::hierarchy::authorize(&policy, &caller, &target, verb, wire::now_seconds());
    json!({
        "ok": true, "decision": verdict.decision(), "reason": verdict.reason, "detail": verdict.detail,
        "verb": verb.as_str(), "from": {"node_id": caller.node_id, "level": caller.level},
        "to": {"node_id": target.node_id, "level": target.level},
    })
}

/// `host.mesh_call(request_json)` — see [`dispatch`].
pub extern "C-unwind" fn mesh_call(l: *mut LuaState) -> c_int {
    let text = arg_string(l, 1).unwrap_or_else(|| "{}".into());
    let answer = match serde_json::from_str::<Value>(&text) {
        Ok(request) => {
            if request.get("dry_run").and_then(Value::as_bool).unwrap_or(false) {
                dry_run(&request)
            } else {
                dispatch(&request)
            }
        }
        Err(error) => json!({"ok": false, "error": "mesh_bad_request", "detail": error.to_string(), "fallback": null}),
    };
    push_json(l, &answer);
    1
}

/// The node's handler: hand the admitted call to this process's own `/node/admitted` route.
///
/// The mesh listener authenticates and authorizes the caller against the roster; the capability then
/// runs on a node-thread, inside the node's own interpreter, exactly as any other call does. The hop
/// carries a **one-shot ticket** minted by the listener ([`admission::tickets`]): the local route can
/// prove which decision it is carrying, so the local hop is not a way to skip the roster — and the
/// node's own admission (Lua) consumes the same decision instead of asking the operator pins.
///
/// The caller's own `/node/call` request and the headers it signed travel verbatim: the mesh added
/// the roster's verdict, not a second, weaker signature.
pub struct LoopbackHandler {
    pub base: String,
    pub timeout: Duration,
}

impl LoopbackHandler {
    pub fn new(node_port: u16, timeout: Duration) -> LoopbackHandler {
        LoopbackHandler { base: format!("127.0.0.1:{node_port}"), timeout }
    }
}

impl Handler for LoopbackHandler {
    fn handle(&self, call: &Call) -> Reply {
        // Minted from a call that was just admitted: caller, key, capability and request id.
        let ticket = admission::tickets::mint_for(
            &call.from.node_id,
            &call.from.public_key,
            &call.capability,
            &call.request_id,
        );
        let mut headers = call.inner.headers.clone();
        headers.push(("x-wa-mesh-ticket".to_string(), ticket.id.clone()));
        match http::request(
            &self.base,
            "POST",
            "/node/admitted",
            &headers,
            call.inner.body.as_bytes(),
            Duration::from_secs(3),
            self.timeout,
            http::MAX_BODY,
        ) {
            Ok(response) => Reply { status: response.status, body: response.body_text() },
            Err(error) => {
                eprintln!("[mesh] loopback /node/admitted failed: {error}");
                Reply::error(503, "handler_unavailable")
            }
        }
    }
}

/// Start the listener for a node whose HTTP port is `node_port`, or `None` when the node has neither
/// the flag nor the operator's `mesh.enabled` statement in its policy. Called from `serve.rs`: the only
/// thing this change adds to the serve path.
pub fn spawn_from_env(node_port: u16) -> Option<Server> {
    if !enabled() {
        return None;
    }
    let Some(port) = env("WASM_AGENT_MESH_PORT").and_then(|value| value.parse::<u16>().ok()) else {
        eprintln!("[mesh] WA_MESH=1 but WASM_AGENT_MESH_PORT is unset: not listening");
        return None;
    };
    let bind = format!("{}:{port}", env("WASM_AGENT_MESH_BIND").unwrap_or_else(|| "127.0.0.1".into()));
    let policy = match MeshPolicy::from_policy_file(&Paths::resolve().policy) {
        Ok(policy) => policy,
        Err(error) => {
            eprintln!("[mesh] policy unreadable, not listening: {}", error.0);
            return None;
        }
    };
    let paths = Paths::resolve().with_policy(&policy);
    let identity = match Identity::load(&paths.key) {
        Ok(identity) => identity,
        Err(error) => {
            eprintln!("[mesh] identity unavailable, not listening: {error}");
            return None;
        }
    };
    let audit = audit_sink(&paths);
    let handler = Arc::new(LoopbackHandler::new(node_port, Duration::from_secs(120)));
    // The node's own files, asked per call: a roster installed while this node is running is in force
    // on the next call, which is what makes `wa fleet push-roster` verifiable by a mesh call.
    let source: Arc<dyn admission::Source> = Arc::new(admission::NodeFiles {
        policy: paths.policy.clone(),
        roster: paths.roster.clone(),
        config: paths.config.clone(),
    });
    match Server::start(ServerConfig::with_source(bind, identity, source, handler, audit)) {
        Ok(server) => {
            eprintln!(
                "[mesh] listening on {} (roster {})",
                server.local_addr(),
                paths
                    .roster
                    .file_name()
                    .map(|name| name.to_string_lossy().to_string())
                    .unwrap_or_default()
            );
            Some(server)
        }
        Err(error) => {
            eprintln!("[mesh] listener not started: {error}");
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_node_files(home: &std::path::Path, fleet: &Identity, node: &crate::testkit::Member, roster: &Roster, enabled: bool) {
        let config = home.join(".wasm-agent");
        std::fs::create_dir_all(&config).expect("config dir");
        // The node's own key, where the mount looks for it.
        std::fs::copy(&node.key_path, config.join("node.key")).expect("node key");
        std::fs::write(
            config.join("policy.json"),
            json!({"version": 1, "components": {}, "mesh": {
                "version": 1, "roster_key": fleet.public_key, "enabled": enabled}})
            .to_string(),
        )
        .expect("policy");
        std::fs::write(
            config.join("mesh-roster.json"),
            serde_json::to_string_pretty(roster).expect("roster json"),
        )
        .expect("roster");
    }

    /// A relayed inbound envelope, decided from the node's own files: this is the call `serve.rs` and a
    /// bound node's Lua runtime make, and it must work without the process flag — a roster pushed to a
    /// running node cannot restart it to get one.
    #[test]
    fn an_inbound_envelope_is_decided_by_the_roster_the_nodes_own_files_name() {
        let _lock = crate::testkit::ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let home = crate::testkit::temp_dir("admit-home");
        let fleet = crate::testkit::fleet_key();
        let target = crate::testkit::Member::new("target", 1, &[]);
        let caller = crate::testkit::Member::new("caller", 0, &[]);
        let roster = crate::testkit::roster_of(&fleet, vec![target.node.clone(), caller.node.clone()]);
        write_node_files(&home, &fleet, &target, &roster, true);
        let _env = crate::testkit::EnvGuard::set(&[
            ("WASM_AGENT_HOME", Some(home.to_str().unwrap())),
            ("WASM_AGENT_NODE_KEY", None),
            ("WA_MESH", None),
            ("WASM_AGENT_MESH", None),
            ("WASM_AGENT_MESH_ROSTER", None),
            ("WASM_AGENT_MESH_CACHE", None),
            ("WA_GRANT_POLICY", None),
            ("WASM_AGENT_RELAY", None),
        ]);
        assert!(!enabled(), "the process flag is off: the policy is what enables this node");

        let inner = Inner {
            body: json!({"from_node_id": caller.node.node_id, "to_node_id": target.node.node_id,
                          "capability": "read", "args": {}})
            .to_string(),
            headers: vec![("X-WA-Node".into(), caller.node.node_id.clone())],
        };
        let envelope = crate::wire::MeshCall {
            schema: crate::wire::SCHEMA,
            request_id: "admit-1".into(),
            from_node_id: caller.node.node_id.clone(),
            to_node_id: target.node.node_id.clone(),
            capability: "read".into(),
            args: json!({}),
            inner_body: inner.body.clone(),
            inner_headers: inner.headers.clone(),
        };
        let body = envelope.encode();
        let ts = wire::now_seconds();
        let signature = caller.identity.sign(&crate::wire::MeshCall::call_message(&caller.node.node_id, ts, &body));
        let headers = [
            (admission::MESH_HEADER.to_string(), "1".to_string()),
            (admission::CARRIER_HEADER.to_string(), "relay".to_string()),
            ("x-wa-node".to_string(), caller.node.node_id.clone()),
            ("x-wa-pub".to_string(), caller.node.public_key.clone()),
            ("x-wa-ts".to_string(), ts.to_string()),
            ("x-wa-sig".to_string(), signature),
        ];
        let pairs: Vec<Value> = headers.iter().map(|(name, value)| json!([name, value])).collect();
        let answer = dispatch(&json!({"admit": {"headers": pairs, "body": body, "transport": "relay"}}));
        assert_eq!(answer["ok"], true, "{answer}");
        assert_eq!(answer["caller_node_id"], caller.node.node_id);
        assert_eq!(answer["verb"], "read");
        assert_eq!(answer["reason"], "hierarchy_allowed");
        assert_eq!(answer["inner_body"], inner.body, "the caller's own request is what runs");
        // The same signed bytes again: a replay, refused on any path.
        let replay = dispatch(&json!({"admit": {"headers": pairs, "body": body, "transport": "relay"}}));
        assert_eq!(replay["error"], "mesh_refused", "{replay}");
        assert!(replay["answer"].as_str().unwrap().contains("replayed_request"), "{replay}");
    }

    /// A node with no roster in its own policy hands the call back to today's admission (the pins),
    /// with the caller's own request — never to something weaker, and never to a mesh guess.
    #[test]
    fn a_node_without_a_roster_hands_the_call_back_to_todays_pins() {
        let _lock = crate::testkit::ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let home = crate::testkit::temp_dir("admit-legacy-home");
        let config = home.join(".wasm-agent");
        std::fs::create_dir_all(&config).expect("config dir");
        let node_identity = Identity::load(&config.join("node.key")).expect("node identity");
        std::fs::write(config.join("policy.json"), json!({"version": 1, "components": {}}).to_string()).expect("policy");
        let _env = crate::testkit::EnvGuard::set(&[
            ("WASM_AGENT_HOME", Some(home.to_str().unwrap())),
            ("WASM_AGENT_NODE_KEY", None),
            ("WA_MESH", Some("1")),
            ("WASM_AGENT_MESH", None),
            ("WASM_AGENT_MESH_ROSTER", None),
            ("WASM_AGENT_MESH_CACHE", None),
            ("WA_GRANT_POLICY", None),
        ]);
        let caller = crate::testkit::Member::new("caller-legacy", 0, &[]);
        let body = crate::wire::MeshCall {
            schema: crate::wire::SCHEMA,
            request_id: "legacy-1".into(),
            from_node_id: caller.node.node_id.clone(),
            to_node_id: node_identity.node_id.clone(),
            capability: "read".into(),
            args: json!({}),
            inner_body: "{\"capability\":\"read\"}".into(),
            inner_headers: vec![("X-WA-Node".into(), caller.node.node_id.clone())],
        }
        .encode();
        let answer = dispatch(&json!({"admit": {
            "headers": [[admission::MESH_HEADER, "1"], ["x-wa-node", caller.node.node_id]],
            "body": body,
            "transport": "relay",
        }}));
        assert_eq!(answer["error"], "mesh_legacy", "{answer}");
        assert_eq!(answer["inner_body"], "{\"capability\":\"read\"}",
            "today's path gets the caller's own request");
    }

    #[test]
    fn with_the_flag_unset_nothing_is_touched() {
        // The flag lives in the process environment, so this test excludes the one other test that
        // sets it (see `testkit::ENV_LOCK`) instead of hoping the order is kind.
        let _lock = crate::testkit::ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let _env = crate::testkit::EnvGuard::set(&[("WA_MESH", None), ("WASM_AGENT_MESH", None)]);
        assert!(!enabled());
        let answer = dispatch(&json!({"node": "anyone", "capability": "read"}));
        assert_eq!(answer["error"], "mesh_disabled");
        assert_eq!(answer["fallback"], serde_json::Value::Null);
        assert!(spawn_from_env(8899).is_none(), "the mount must be silent and bind nothing");
    }
}
