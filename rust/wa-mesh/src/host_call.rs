//! Wiring the crate into a node: the listener mount and `host.mesh_call`.
//!
//! Everything here is behind `WA_MESH=1` (`WASM_AGENT_MESH=1` is read too). With the flag unset the
//! node never binds the listener, and `host.mesh_call` answers `mesh_disabled` **without touching the
//! network or the disk** — which is what makes "with the flag unset, behaviour is byte-for-byte
//! unchanged" a property of the code rather than a promise in a document.
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
//! | listener port | `WASM_AGENT_MESH_PORT` | none: a flag alone never opens a port |
//! | listener address | `WASM_AGENT_MESH_BIND` | `127.0.0.1` |
use crate::audit::{FileSink, Sink, StderrSink, Tee};
use crate::cache::PeerCache;
use crate::client::{Client, ClientConfig, Inner};
use crate::hierarchy::Verdict;
use crate::http;
use crate::identity::Identity;
use crate::policy::MeshPolicy;
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
    env("WA_MESH").as_deref() == Some("1") || env("WASM_AGENT_MESH").as_deref() == Some("1")
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
    if !enabled() {
        return disabled();
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

/// The node's handler: forward the caller's own request to the node's loopback `/node/call`.
///
/// This is the seam `docs/MESH.md` §8 names. The mesh authenticates and authorizes the caller against
/// the roster; the node's own peer path then executes the capability and verifies the caller the way
/// it does today (a fresh rendezvous lookup). So the mesh adds a direct path and the hierarchy, and
/// the *execution* trust basis stays the existing one until `lua/core/server.lua` learns to accept a
/// roster-verified caller on the loopback hop.
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
        match http::request(
            &self.base,
            "POST",
            "/node/call",
            &call.inner.headers,
            call.inner.body.as_bytes(),
            Duration::from_secs(3),
            self.timeout,
            http::MAX_BODY,
        ) {
            Ok(response) => Reply { status: response.status, body: response.body_text() },
            Err(error) => {
                eprintln!("[mesh] loopback /node/call failed: {error}");
                Reply::error(503, "handler_unavailable")
            }
        }
    }
}

/// Start the listener for a node whose HTTP port is `node_port`, or `None` when the flag or the port
/// is unset. Called from `serve.rs`: the only thing this change adds to the serve path.
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
    let roster = match Roster::from_file(&paths.roster) {
        Ok(roster) => roster,
        Err(error) => {
            eprintln!("[mesh] roster unreadable, not listening: {}", error.0);
            return None;
        }
    };
    let identity = match Identity::load(&paths.key) {
        Ok(identity) => identity,
        Err(error) => {
            eprintln!("[mesh] identity unavailable, not listening: {error}");
            return None;
        }
    };
    let audit = audit_sink(&paths);
    let handler = Arc::new(LoopbackHandler::new(node_port, Duration::from_secs(120)));
    match Server::start(ServerConfig::new(bind, identity, roster, policy, handler, audit)) {
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
