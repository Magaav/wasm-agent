//! Wiring the crate into a node: the listener mount and `host.mesh_call`.
//!
//! Whether the mesh is on for this node is answered in exactly one place, [`crate::gate`]: the process
//! flag (`WA_MESH=1`/`WASM_AGENT_MESH=1`), else the operator's own `mesh.enabled` in `policy.json`,
//! else off — read per ask and cached by mtime, because a roster pushed to a *running* node cannot
//! restart it. With neither, the node never binds the listener and `host.mesh_call` answers
//! `mesh_disabled` after one `stat` of `policy.json` and no network at all — which is what makes "with
//! the flag unset and no mesh section, behaviour is byte-for-byte unchanged" a property of the code
//! rather than a promise in a document.
//!
//! Every gate in the node asks [`crate::gate`]: this capability ([`dispatch`], [`dry_run`]), the relay
//! hop and therefore `mesh_peer_call` in `wa-capabilities` ([`enabled_at_runtime`]), the mount
//! ([`Settings`]), and `lua/core/nodes.lua`'s remote-call gate, which asks with
//! `host.mesh_call({"gate": true})` before it decides whether to try the mesh first.
//!
//! Request modes of `host.mesh_call` (one capability, so the catalogue does not grow for a feature
//! only a fleet member ever uses):
//!
//! | request | answer | who uses it |
//! | --- | --- | --- |
//! | `{gate: true}` | `{ok, enabled, from, problem}` — the gate, nothing else | `nodes.lua`'s remote gate |
//! | `{node, capability, args, inner_body, inner_headers, peers?}` | the call, or its refusal | `wa call`, `nodes.remote_call` |
//! | `{node, capability, dry_run: true}` | the verdict only, no network | an operator, and a test |
//! | `{admit: {headers, body, transport}}` | the roster's decision on an *inbound* envelope | the node's own admission (Lua), so pins are not the authority when a roster is |
//! | `{seal: {reply, caller}}` | the signed answer to send back | the same, for a relayed answer |
//! | `{attest: {caller, verb, capability, signature}}` | the node-signed proof a managed node admits by verb | the mount, and `scripts/test-mesh-attest.lua` |
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
use crate::attest;
use crate::attestation as attest_signer;
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
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use wa_host_support::json::push_json;
use wa_host_support::lua::{arg_string, LuaState};

pub const AUDIT_LIMIT_BYTES: u64 = 8 * 1024 * 1024;

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().map(|value| value.trim().to_string()).filter(|value| !value.is_empty())
}

/// Is the feature on for this *process*? `WA_MESH=1`, or `WASM_AGENT_MESH=1` — the environment's own
/// statement, and nothing else. The gate a call path asks is [`enabled_at_runtime`].
pub fn enabled() -> bool {
    admission::flag_on()
}

/// Is it on for this node, process flag or the operator's own `policy.json` statement?
pub fn enabled_here(policy: &MeshPolicy) -> bool {
    admission::in_force(policy)
}

/// The gate for every path that is not the mount (the caller, the relay hop, the Lua remote gate):
/// environment, then this node's own `policy.json` `mesh.enabled`, then off ([`crate::gate`]).
///
/// Read per call, cached by the policy file's mtime and size, because a roster pushed to a running
/// node cannot restart it. A policy that cannot be read is `false` here: the relay hop then runs
/// today's admission, never a guess.
pub fn enabled_at_runtime() -> bool {
    crate::gate::cached(&Paths::resolve().policy).enabled
}

/// The address the listener binds when nothing says otherwise: loopback, so a flag alone never opens
/// a port to the LAN.
pub const DEFAULT_BIND: &str = "127.0.0.1";
/// How often the supervisor re-reads this node's settings when the environment does not say.
pub const SUPERVISOR_POLL: Duration = Duration::from_millis(1000);
pub const SUPERVISOR_POLL_ENV: &str = "WASM_AGENT_MESH_POLL_MS";

/// What this node's files and process environment say the mesh should be doing now.
///
/// The order is the one the rest of the node uses — **environment first, then the persisted setting,
/// then the default** (`off`, and no port) — and each answer carries where it came from, because the
/// supervisor logs one line when the state changes and an operator has to be able to tell a flag from
/// a pushed file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Settings {
    pub enabled: bool,
    pub port: Option<u16>,
    pub bind: String,
    pub enabled_from: &'static str,
    pub port_from: &'static str,
    pub bind_from: &'static str,
}

impl Settings {
    pub fn resolve(policy: &MeshPolicy) -> Settings {
        // The same rule every other gate uses, so the mount and a call can never disagree about
        // whether this node is on: environment, then the operator's file, then the default — which is
        // on when a roster verifies against the pinned key (docs/MESH.md, "On by default").
        let verified = crate::gate::roster_verified(policy, &Paths::resolve().config);
        let switch = crate::gate::decide_with_roster(crate::gate::env_answer(), Some(policy), verified);
        let (enabled, enabled_from) = (switch.enabled, switch.label());
        let (port, port_from) = match env("WASM_AGENT_MESH_PORT")
            .and_then(|value| value.parse::<u16>().ok())
            .filter(|port| *port != 0)
        {
            Some(port) => (Some(port), "environment WASM_AGENT_MESH_PORT"),
            None => match policy.port {
                Some(port) => (Some(port), "policy.json mesh.port"),
                None => (None, "unset"),
            },
        };
        let (bind, bind_from) = match env("WASM_AGENT_MESH_BIND") {
            Some(bind) => (bind, "environment WASM_AGENT_MESH_BIND"),
            None => match policy.bind.as_deref().map(str::trim).filter(|bind| !bind.is_empty()) {
                Some(bind) => (bind.to_string(), "policy.json mesh.bind"),
                None => (DEFAULT_BIND.to_string(), "default"),
            },
        };
        Settings { enabled, port, bind, enabled_from, port_from, bind_from }
    }

    /// The `host:port` the listener would bind, when this node is on and a port was named.
    pub fn bind_address(&self) -> Option<String> {
        self.port.map(|port| format!("{}:{port}", self.bind))
    }
}

/// What the mount is doing, for `/health`, an operator, and the tests.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct MountStatus {
    pub enabled: bool,
    pub port: Option<u16>,
    pub bind: String,
    pub listening: bool,
    pub addr: String,
    pub roster: String,
    pub roster_verified: bool,
    /// The last thing the supervisor did or could not do: `mounted`, `unmounted`, or the reason.
    pub reason: String,
    /// How many times the mount changed state (a mount, an unmount, a rebind).
    pub changes: u32,
    pub mounts: u32,
    pub unmounts: u32,
    pub poll_ms: u64,
}

impl MountStatus {
    pub fn to_json(&self) -> Value {
        json!({
            "enabled": self.enabled,
            "port": self.port,
            "bind": self.bind,
            "listening": self.listening,
            "addr": self.addr,
            "roster": self.roster,
            "roster_verified": self.roster_verified,
            "reason": self.reason,
            "changes": self.changes,
            "mounts": self.mounts,
            "unmounts": self.unmounts,
            "poll_ms": self.poll_ms,
        })
    }
}

struct Mounted {
    server: Server,
    bind: String,
    port: u16,
}

/// The live mount of the mesh listener: one thread re-reading this node's settings.
///
/// `WA_MESH=1` is a process switch and a live process cannot change its environment, so enabling the
/// mesh on a running node has to be a file the node re-reads. This thread is that re-read: it resolves
/// [`Settings`] (environment, then `policy.json`'s `mesh` section, then off), and **mounts the
/// listener** when the node turns the mesh on with a port, **moves it** when the port or bind changes,
/// and **unmounts it** — closing the socket and freeing the port — when the node turns it off. No
/// restart, and no restart-shaped gap: the roster is read per call by the listener's own source, so a
/// node that comes up this way decides by the roster on its very next call.
///
/// Everything the thread owns (`Server`) is dropped by dropping the [`Supervisor`], which joins it: the
/// node's shutdown path stays the one thing that ends a listener.
pub struct Supervisor {
    stop: Arc<AtomicBool>,
    join: Option<std::thread::JoinHandle<()>>,
    status: Arc<Mutex<MountStatus>>,
    poll: Duration,
}

impl Supervisor {
    /// The mount's state, as of the last poll.
    pub fn status(&self) -> MountStatus {
        self.status.lock().map(|status| status.clone()).unwrap_or_default()
    }

    pub fn poll(&self) -> Duration {
        self.poll
    }
}

impl Drop for Supervisor {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
    }
}

fn poll_interval() -> Duration {
    env(SUPERVISOR_POLL_ENV)
        .and_then(|value| value.parse::<u64>().ok())
        .map(|ms| Duration::from_millis(ms.clamp(20, 60_000)))
        .unwrap_or(SUPERVISOR_POLL)
}

/// Start the live mount for a node whose own HTTP port is `node_port`.
///
/// Always started (the poll is cheap and a node that is off must still notice being turned on); the
/// listener is opened only when the settings say so. `node_port` is where an admitted call is handed
/// to this process's own `/node/admitted`.
pub fn spawn_supervisor(node_port: u16) -> Supervisor {
    let stop = Arc::new(AtomicBool::new(false));
    let poll = poll_interval();
    let status = Arc::new(Mutex::new(MountStatus {
        bind: DEFAULT_BIND.to_string(),
        poll_ms: poll.as_millis() as u64,
        ..MountStatus::default()
    }));
    let thread_stop = stop.clone();
    let thread_status = status.clone();
    let join = std::thread::Builder::new()
        .name("wa-mesh-mount".into())
        .spawn(move || supervise(node_port, poll, thread_stop, thread_status))
        .map_err(|error| eprintln!("[mesh] the mount supervisor could not start: {error}"))
        .ok();
    Supervisor { stop, join, status, poll }
}

fn publish(status: &Arc<Mutex<MountStatus>>, next: MountStatus) {
    if let Ok(mut held) = status.lock() {
        *held = next;
    }
}

/// The settings file's timestamp, so a node that is not being reconfigured costs one `stat` a second
/// rather than a JSON parse. `None` when the file does not exist (then it is re-read: cheap, and the
/// node may be about to be given one).
fn policy_stamp(path: &std::path::Path) -> Option<std::time::SystemTime> {
    std::fs::metadata(path).and_then(|metadata| metadata.modified()).ok()
}

/// A file time is only a safe cache key once it has *settled*.
///
/// Windows derives file times from a clock that ticks about every 15.6 ms (a filesystem may be coarser
/// still), so a writer's truncate and the write that follows it can carry the same stamp. A cache keyed
/// on a fresh stamp would then miss the second write and keep serving the first answer until something
/// else touched the file - which is a mount that never follows the policy. While a stamp is younger
/// than this, the policy is re-read on every poll; a settled file costs exactly what it did before.
const STAMP_SETTLE: std::time::Duration = std::time::Duration::from_secs(1);

fn stamp_settled(stamp: std::time::SystemTime) -> bool {
    std::time::SystemTime::now()
        .duration_since(stamp)
        .map(|age| age >= STAMP_SETTLE)
        .unwrap_or(false)
}

fn supervise(node_port: u16, poll: Duration, stop: Arc<AtomicBool>, status: Arc<Mutex<MountStatus>>) {
    let mut mounted: Option<Mounted> = None;
    let mut last_problem = String::new();
    let mut cached: Option<(std::time::SystemTime, Option<MeshPolicy>)> = None;
    while !stop.load(Ordering::SeqCst) {
        let paths = Paths::resolve();
        // A policy that cannot be read is not "off": the node cannot be sure what it says, and taking
        // a listener down (or bringing one up) on a partial read would be the silent surprise this
        // whole file exists to avoid. The last state stands, and the reason is on stderr once.
        let stamp = policy_stamp(&paths.policy);
        let policy = match (&cached, stamp) {
            // Unchanged since the last read, and settled: the answer cannot have changed either.
            (Some((cached_stamp, policy)), Some(stamp))
                if *cached_stamp == stamp && stamp_settled(stamp) => policy.clone(),
            _ => {
                let loaded = match MeshPolicy::from_policy_file(&paths.policy) {
                    Ok(policy) => Some(policy),
                    Err(error) => {
                        if last_problem != error.0 {
                            eprintln!("[mesh] policy unreadable, leaving the mount as it is: {}", error.0);
                            last_problem = error.0;
                        }
                        None
                    }
                };
                // A *failed* read is never cached. A writer truncates the file and then writes it, and
                // Windows can give the two the same file-time tick; caching "unreadable" under that
                // stamp would then pin the empty answer until something else changed the file, which is
                // a mount that never comes up. Re-reading an unchanged unreadable file costs one small
                // read per poll, and the log line above is still printed once per distinct reason.
                if let (Some(stamp), Some(policy)) = (stamp, &loaded) {
                    cached = Some((stamp, Some(policy.clone())));
                }
                loaded
            }
        };
        if let Some(policy) = policy {
            let settings = Settings::resolve(&policy);
            let paths = paths.with_policy(&policy);
            let desired = if settings.enabled { settings.port } else { None };
            let same = match (&mounted, desired) {
                (Some(mounted), Some(port)) => mounted.port == port && mounted.bind == settings.bind,
                (None, None) => true,
                _ => false,
            };
            if !same {
                // Unmount first: a port change must not leave the old socket bound while the new one
                // is attempted, or a failed rebind would look like "still listening" with the wrong
                // settings.
                if let Some(closed) = mounted.take() {
                    let addr = closed.server.local_addr().to_string();
                    drop(closed);
                    let mut next = status.lock().map(|held| held.clone()).unwrap_or_default();
                    next.enabled = settings.enabled;
                    next.port = settings.port;
                    next.bind = settings.bind.clone();
                    next.listening = false;
                    next.addr.clear();
                    next.unmounts = next.unmounts.saturating_add(1);
                    next.changes = next.changes.saturating_add(1);
                    next.reason = if desired.is_none() {
                        if settings.enabled {
                            "unmounted: mesh.enabled is on but no port is configured".to_string()
                        } else {
                            "unmounted: policy.json mesh.enabled is off".to_string()
                        }
                    } else {
                        format!("moved: {} is no longer the configured address", addr)
                    };
                    eprintln!("[mesh] {} ({addr} closed)", next.reason);
                    publish(&status, next);
                }
                if let Some(port) = desired {
                    match start_listener(&paths, &policy, &settings, port, node_port) {
                        Ok((server, roster_verified, roster)) => {
                            let addr = server.local_addr().to_string();
                            let mut next = status.lock().map(|held| held.clone()).unwrap_or_default();
                            next.enabled = true;
                            next.port = Some(port);
                            next.bind = settings.bind.clone();
                            next.listening = true;
                            next.addr = addr.clone();
                            next.roster = roster.clone();
                            next.roster_verified = roster_verified;
                            next.mounts = next.mounts.saturating_add(1);
                            next.changes = next.changes.saturating_add(1);
                            next.reason = "mounted".to_string();
                            eprintln!(
                                "[mesh] listening on {addr} (roster {roster}{})",
                                if roster_verified { ", verified" } else { ", NOT verified: today's pins decide" }
                            );
                            publish(&status, next);
                            last_problem.clear();
                            mounted = Some(Mounted { server, bind: settings.bind.clone(), port });
                        }
                        Err(error) => {
                            let mut next = status.lock().map(|held| held.clone()).unwrap_or_default();
                            next.enabled = true;
                            next.port = Some(port);
                            next.bind = settings.bind.clone();
                            next.listening = false;
                            next.reason = format!("not mounted: {error}");
                            if last_problem != error {
                                eprintln!("[mesh] listener not started on {}:{port}: {error}", settings.bind);
                                last_problem = error;
                            }
                            publish(&status, next);
                        }
                    }
                }
            } else {
                // Nothing to change. Keep the reported settings current anyway (a node that was never
                // mounted still answers for `/health` with what it *would* do).
                if let Ok(mut held) = status.lock() {
                    held.enabled = settings.enabled;
                    held.port = settings.port;
                    held.bind = settings.bind.clone();
                }
            }
        }
        std::thread::sleep(poll);
    }
    // The node is going away: closing the socket is the supervisor's last act, in its own thread, so
    // a dropped `Server` never blocks the caller that asked the node to stop.
    drop(mounted);
}

fn start_listener(
    paths: &Paths,
    policy: &MeshPolicy,
    settings: &Settings,
    port: u16,
    node_port: u16,
) -> Result<(Server, bool, String), String> {
    let identity = Identity::load(&paths.key)?;
    let handler_identity = Identity::load(&paths.key)?;
    let roster_file = paths
        .roster
        .file_name()
        .map(|name| name.to_string_lossy().to_string())
        .unwrap_or_default();
    let roster_verified = Roster::from_file(&paths.roster)
        .and_then(|roster| crate::seam::verify_roster(&roster, &policy.roster_key, wire::now_seconds()))
        .is_ok();
    let handler = Arc::new(
        LoopbackHandler::new(node_port, Duration::from_secs(120)).with_identity(handler_identity),
    );
    let source: Arc<dyn admission::Source> = Arc::new(admission::NodeFiles {
        policy: paths.policy.clone(),
        roster: paths.roster.clone(),
        config: paths.config.clone(),
    });
    let bind = format!("{}:{port}", settings.bind);
    let server = Server::start(ServerConfig::with_source(bind, identity, source, handler, audit_sink(paths)))?;
    Ok((server, roster_verified, roster_file))
}

/// The mount's state as JSON: what `/health` and `wa fleet push-roster`'s verification can report.
pub fn mount_status_json(supervisor: &Supervisor) -> Value {
    supervisor.status().to_json()
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

/// The gate's own answer: is the mesh on for this node now, and where does that come from. It is asked
/// by `lua/core/nodes.lua` before a peer call, so the CLI's remote path uses the *same* resolver as
/// `host.mesh_call` itself instead of reading `WA_MESH` on its own (the 07/11 rollout: a node whose
/// `policy.json` said `mesh.enabled: true` still took the legacy path).
fn gate_json(switch: &crate::gate::Switch) -> Value {
    json!({
        "ok": true,
        "enabled": switch.enabled,
        "from": switch.label(),
        "problem": switch.problem,
    })
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
    // The gate itself, before anything that needs it: a caller asks this to learn whether to try the
    // mesh at all, and it must be answerable while the mesh is off (that is the answer).
    let paths = Paths::resolve();
    let switch = crate::gate::cached(&paths.policy);
    if request.get("gate").is_some() {
        return gate_json(&switch);
    }
    // Everything else — calling, admitting an inbound envelope, sealing an answer — is the feature
    // itself: the process flag, or the operator's own statement in `policy.json` (`mesh.enabled`),
    // which is what a roster pushed to a *running* node writes. The environment of a live process
    // cannot change, and a bootstrap that needed a restart could not verify itself.
    if !switch.enabled {
        return disabled();
    }
    if let Some(inbound) = request.get("admit") {
        return admit_inbound(inbound);
    }
    if let Some(seal) = request.get("seal") {
        return seal_reply(seal);
    }
    if let Some(attest) = request.get("attest") {
        return attest_call(attest);
    }
    let started = wire::now_millis();
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
    if let Err(error) = crate::seam::verify_roster(&roster, &policy.roster_key, now_s) {
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
    if let Err(error) = crate::cache::save(&mut cache, &paths.cache, now_ms) {
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
        Admission::Allow(allowed) => {
            // The mount holds this node's identity and signs *only here*, after `authorize()` said
            // allow: the proof a managed node's `wa_node_call` admits this call by its verb
            // ([`crate::attest`], docs/MESH.md §9). Nothing else in this crate signs an attestation.
            let attestation = attest_signer::sign(
                admitter.identity(),
                &allowed.call.from.node_id,
                allowed.verb.as_str(),
                &allowed.call.capability,
                &attest::caller_signature(&allowed.call.inner.headers),
                wire::now_seconds(),
            );
            json!({
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
                "attestation": attestation,
                "inner_body": allowed.call.inner.body,
                "inner_headers": pairs_json(&allowed.call.inner.headers),
            })
        }
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
    match crate::seam::verify_roster(&roster, key, wire::now_seconds()) {
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

/// `{attest: {caller, verb, capability, signature}}`: the node-signed attestation a managed node's
/// `wa_node_call` admits a roster-authorized call by (`docs/MESH.md` §9, [`crate::attest`]).
///
/// It signs one message and nothing else, with this node's own key: a Lua caller could already sign
/// arbitrary text with `host.sign`, and a remote caller cannot reach this at all. The mount calls the
/// same function directly, only after `authorize()` returned allow.
fn attest_call(request: &Value) -> Value {
    let field = |name: &str| request.get(name).and_then(Value::as_str).unwrap_or_default().to_string();
    let (caller, verb, capability) = (field("caller"), field("verb"), field("capability"));
    if caller.is_empty() || capability.is_empty() || !matches!(verb.as_str(), "read" | "control" | "call") {
        return json!({
            "ok": false,
            "error": "mesh_bad_request",
            "detail": "caller, capability and one of read/control/call are required",
        });
    }
    match attest_signer::from_files(&Paths::resolve(), &caller, &verb, &capability, &field("signature")) {
        Ok(attestation) => json!({"ok": true, "attestation": attestation}),
        Err(error) => unavailable("identity_unavailable", error),
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
        port: request
            .get("port")
            .and_then(Value::as_u64)
            .and_then(|port| u16::try_from(port).ok()),
        bind: request.get("bind").and_then(Value::as_str).map(str::to_string),
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
    let paths = Paths::resolve();
    if !crate::gate::cached(&paths.policy).enabled {
        return disabled();
    }
    let policy = match MeshPolicy::from_policy_file(&paths.policy) {
        Ok(policy) => policy,
        Err(error) => return unavailable("policy_unreadable", error.0),
    };
    let paths = paths.with_policy(&policy);
    let roster = match Roster::from_file(&paths.roster) {
        Ok(roster) => roster,
        Err(error) => return unavailable("roster_unreadable", error.0),
    };
    if let Err(error) = crate::seam::verify_roster(&roster, &policy.roster_key, wire::now_seconds()) {
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
    let verdict: Verdict = crate::seam::decide(&policy, &caller, &target, verb, wire::now_seconds());
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
    /// This node's identity, used to sign the attestation `wa_node_call` admits by verb. `None` only
    /// in a test that is not exercising that seam (then the ticket carries no attestation, and the
    /// node falls back to its legacy capability list).
    pub identity: Option<Identity>,
}

impl LoopbackHandler {
    pub fn new(node_port: u16, timeout: Duration) -> LoopbackHandler {
        LoopbackHandler { base: format!("127.0.0.1:{node_port}"), timeout, identity: None }
    }

    /// The mount's identity: the same key file the listener authenticates with, loaded a second time
    /// because one `Identity` cannot be in two places.
    pub fn with_identity(mut self, identity: Identity) -> Self {
        self.identity = Some(identity);
        self
    }
}

impl Handler for LoopbackHandler {
    fn handle(&self, call: &Call) -> Reply {
        // Signed here, after the listener's `authorize()` allowed *this* call: the ticket carries the
        // decision, and the attestation makes the node's own admission widen to the verb it proves.
        let attestation = self
            .identity
            .as_ref()
            .map(|identity| {
                attest_signer::sign(
                    identity,
                    &call.from.node_id,
                    call.verb.as_str(),
                    &call.capability,
                    &attest::caller_signature(&call.inner.headers),
                    wire::now_seconds(),
                )
                .to_string()
            })
            .unwrap_or_default();
        // Minted from a call that was just admitted: caller, key, capability, verb, request id.
        let ticket = admission::tickets::mint_for(
            &call.from.node_id,
            &call.from.public_key,
            &call.capability,
            call.verb.as_str(),
            &call.request_id,
            &attestation,
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
        // The mount signs the attestation a managed node's admission admits by verb, and it names
        // exactly this call: caller, verb, capability and the caller's own request signature.
        let attestation = answer.get("attestation").expect("an allowed call carries an attestation");
        assert_eq!(attestation["caller"], caller.node.node_id);
        assert_eq!(attestation["verb"], "read");
        assert_eq!(attestation["capability"], "read");
        let ts = attestation["ts"].as_u64().unwrap();
        let message = crate::attest::message(
            &target.node.node_id,
            &caller.node.node_id,
            "read",
            "read",
            &crate::attest::caller_signature(&inner.headers),
            ts,
        );
        assert!(crate::identity::verify(
            &target.node.public_key,
            &message,
            attestation["signature"].as_str().unwrap()
        ));
        assert!(message.starts_with(&format!("mesh-allow|{}|", target.node.node_id)));
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
        assert!(
            answer.get("attestation").is_none(),
            "a call the roster did not decide carries no attestation: nothing widens"
        );
    }

    #[test]
    fn with_the_flag_unset_nothing_is_touched() {
        // The flag lives in the process environment, so this test excludes the one other test that
        // sets it (see `testkit::ENV_LOCK`) instead of hoping the order is kind.
        let _lock = crate::testkit::ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let home = crate::testkit::temp_dir("mount-off-home");
        let _env = crate::testkit::EnvGuard::set(&[
            ("WA_MESH", None),
            ("WASM_AGENT_MESH", None),
            ("WASM_AGENT_HOME", Some(home.to_str().unwrap())),
            ("WASM_AGENT_MESH_PORT", None),
            ("WASM_AGENT_MESH_POLL_MS", Some("20")),
        ]);
        assert!(!enabled());
        let answer = dispatch(&json!({"node": "anyone", "capability": "read"}));
        assert_eq!(answer["error"], "mesh_disabled");
        assert_eq!(answer["fallback"], serde_json::Value::Null);
        // A node with no policy section never binds: the supervisor has nothing to mount.
        let supervisor = spawn_supervisor(8899);
        std::thread::sleep(Duration::from_millis(120));
        let status = supervisor.status();
        assert!(!status.listening, "the mount must bind nothing: {status:?}");
        assert_eq!(status.changes, 0, "nothing changed, so nothing was mounted or closed");
    }

    /// One resolver, asked by every gate: the caller path (`dispatch`), the mount (`Settings`), and —
    /// through `{gate: true}` — `lua/core/nodes.lua`'s remote gate. The environment wins in both
    /// directions; the operator's own file is the answer when it says nothing; and a policy-enabled
    /// node's caller path is never `mesh_disabled` (the 07/11 shape).
    #[test]
    fn every_gate_answers_from_the_same_resolver() {
        let _lock = crate::testkit::ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let home = crate::testkit::temp_dir("gate-home");
        let fleet = crate::testkit::fleet_key();
        let node = crate::testkit::Member::new("gate-node", 1, &[]);
        let roster = crate::testkit::roster_of(&fleet, vec![node.node.clone()]);
        write_node_files(&home, &fleet, &node, &roster, true);
        let policy_path = home.join(".wasm-agent").join("policy.json");
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
        crate::gate::reset_cache();
        assert!(!enabled(), "the process flag says nothing");

        // The policy alone: the gate is on and says where that came from.
        let answer = dispatch(&json!({"gate": true}));
        assert_eq!(answer["ok"], true, "{answer}");
        assert_eq!(answer["enabled"], true, "{answer}");
        assert_eq!(answer["from"], "policy.json mesh.enabled", "{answer}");
        // The mount's settings answer the same thing about the same file.
        let policy = MeshPolicy::from_policy_file(&policy_path).expect("policy");
        let settings = Settings::resolve(&policy);
        assert!(settings.enabled);
        assert_eq!(settings.enabled_from, "policy.json mesh.enabled");
        // And the caller path is past the gate: it answers the roster's verdict, not `mesh_disabled`.
        let call = dispatch(&json!({"node": "nobody", "capability": "read"}));
        assert_ne!(call["error"], "mesh_disabled", "a policy-enabled caller tries the mesh: {call}");
        assert_eq!(call["error"], "mesh_unknown_node", "{call}");

        // An explicit `WA_MESH=0` is the operator's own off, and it overrules the file on every gate.
        let _env = crate::testkit::EnvGuard::set(&[("WA_MESH", Some("0"))]);
        crate::gate::reset_cache();
        let off = dispatch(&json!({"gate": true}));
        assert_eq!(off["enabled"], false, "{off}");
        assert_eq!(off["from"], "environment WA_MESH", "{off}");
        assert_eq!(
            dispatch(&json!({"node": "nobody", "capability": "read"}))["error"],
            "mesh_disabled"
        );
        assert!(!Settings::resolve(&policy).enabled);
        assert_eq!(Settings::resolve(&policy).enabled_from, "environment WA_MESH");
        crate::gate::reset_cache();
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn the_settings_are_environment_then_policy_then_off() {
        let _lock = crate::testkit::ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let _env = crate::testkit::EnvGuard::set(&[
            ("WA_MESH", None),
            ("WASM_AGENT_MESH", None),
            ("WASM_AGENT_MESH_PORT", None),
            ("WASM_AGENT_MESH_BIND", None),
        ]);
        // Nothing written: off, no port, loopback.
        let settings = Settings::resolve(&MeshPolicy::empty());
        assert!(!settings.enabled);
        assert_eq!(settings.port, None);
        assert_eq!(settings.bind, DEFAULT_BIND);
        assert_eq!(settings.bind_address(), None);
        assert_eq!(settings.enabled_from, "default off");

        let policy = MeshPolicy::from_policy_text(
            r#"{"version":1,"mesh":{"version":1,"enabled":true,"port":8891,"bind":"0.0.0.0"}}"#,
        )
        .unwrap();
        let settings = Settings::resolve(&policy);
        assert!(settings.enabled);
        assert_eq!(settings.port, Some(8891));
        assert_eq!(settings.bind, "0.0.0.0");
        assert_eq!(settings.bind_address().as_deref(), Some("0.0.0.0:8891"));
        assert_eq!(settings.port_from, "policy.json mesh.port");

        // The environment wins over the persisted setting, in both directions.
        let _env = crate::testkit::EnvGuard::set(&[
            ("WASM_AGENT_MESH_PORT", Some("8892")),
            ("WASM_AGENT_MESH_BIND", Some("127.0.0.1")),
            ("WA_MESH", Some("1")),
        ]);
        let settings = Settings::resolve(&MeshPolicy::empty());
        assert_eq!(settings.port, Some(8892));
        assert_eq!(settings.bind, "127.0.0.1");
        assert!(settings.enabled);
        assert_eq!(settings.enabled_from, "environment WA_MESH");
    }

    /// Wait for `done`, or fail with the last status. The supervisor polls on its own thread, so a
    /// state change is *observed* rather than asserted immediately.
    fn wait_for(name: &str, supervisor: &Supervisor, done: impl Fn(&MountStatus) -> bool) -> MountStatus {
        let deadline = std::time::Instant::now() + Duration::from_secs(30);
        loop {
            let status = supervisor.status();
            if done(&status) {
                return status;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "{name}: gave up waiting for the mount; last status {status:?}"
            );
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    /// One `/mesh/health` attempt. The budget is generous for the same reason `testkit`'s is: a
    /// loopback handshake was measured taking seconds while the machine compiled wasmtime on every
    /// core, and a test that called that "not listening" failed a correct mount.
    fn health(port: u16) -> Option<u16> {
        crate::http::request(
            &format!("127.0.0.1:{port}"),
            "GET",
            "/mesh/health",
            &[],
            b"",
            Duration::from_secs(1),
            Duration::from_secs(1),
            64 * 1024,
        )
        .ok()
        .map(|response| response.status)
    }

    /// Ask `/mesh/health` until it answers or `budget` runs out. A listener that has just bound is
    /// allowed a moment to be reachable; one that is *closed* refuses at once, so the same helper
    /// measures both states.
    fn health_within(port: u16, budget: Duration) -> Option<u16> {
        let deadline = std::time::Instant::now() + budget;
        loop {
            if let Some(status) = health(port) {
                return Some(status);
            }
            if std::time::Instant::now() >= deadline {
                return None;
            }
            std::thread::sleep(Duration::from_millis(25));
        }
    }

    /// The live mount: three enable/disable cycles on a node whose files change under it.
    ///
    /// Nothing here restarts anything. The supervisor is started once (as `serve.rs` starts it), the
    /// node's `policy.json` is rewritten the way `wa fleet push-roster` writes it, and the listener
    /// appears and disappears with it — answering `/mesh/health` and then releasing the port so it can
    /// be bound again. A restart-shaped gap or a leaked socket fails this test.
    #[test]
    fn the_mount_turns_on_and_off_while_the_node_runs() {
        crate::testkit::with_deadline("the_mount_turns_on_and_off_while_the_node_runs", || {
            let _lock = crate::testkit::ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            let home = crate::testkit::temp_dir("mount-live-home");
            let fleet = crate::testkit::fleet_key();
            let node = crate::testkit::Member::new("target", 1, &[]);
            let roster = crate::testkit::roster_of(&fleet, vec![node.node.clone()]);
            write_node_files(&home, &fleet, &node, &roster, false);
            let config = home.join(".wasm-agent");
            let _env = crate::testkit::EnvGuard::set(&[
                ("WASM_AGENT_HOME", Some(home.to_str().unwrap())),
                ("WASM_AGENT_NODE_KEY", None),
                ("WA_MESH", None),
                ("WASM_AGENT_MESH", None),
                ("WASM_AGENT_MESH_PORT", None),
                ("WASM_AGENT_MESH_BIND", None),
                ("WASM_AGENT_MESH_POLL_MS", Some("20")),
            ]);
            let supervisor = spawn_supervisor(1);
            // Off to begin with: the policy has no `enabled` and no port.
            let status = wait_for("start off", &supervisor, |status| !status.listening);
            assert!(!status.enabled);

            for cycle in 1..=3u32 {
                let port = crate::testkit::free_port();
                std::fs::write(
                    config.join("policy.json"),
                    json!({"version": 1, "components": {}, "mesh": {
                        "version": 1, "roster_key": fleet.public_key, "enabled": true,
                        "port": port, "bind": "127.0.0.1"}})
                    .to_string(),
                )
                .unwrap();
                let status = wait_for("enable", &supervisor, |status| status.listening);
                assert_eq!(status.port, Some(port), "cycle {cycle}");
                assert!(status.roster_verified, "cycle {cycle}");
                assert_eq!(health_within(port, Duration::from_secs(10)), Some(200), "cycle {cycle}: the listener answers");

                std::fs::write(
                    config.join("policy.json"),
                    json!({"version": 1, "components": {}, "mesh": {
                        "version": 1, "roster_key": fleet.public_key, "enabled": false,
                        "port": port, "bind": "127.0.0.1"}})
                    .to_string(),
                )
                .unwrap();
                let status = wait_for("disable", &supervisor, |status| !status.listening);
                assert!(!status.enabled, "cycle {cycle}");
                assert_eq!(status.unmounts, cycle, "cycle {cycle}: one unmount per disable");
                // The port is free again: nothing is left bound behind a disabled mount. Binding it is
                // the check, rather than an HTTP probe — a closed loopback port can *time out* on
                // Windows instead of refusing, and a bind answers the question directly.
                let listener = std::net::TcpListener::bind(("127.0.0.1", port))
                    .unwrap_or_else(|error| panic!("cycle {cycle}: port {port} is still stuck: {error}"));
                drop(listener);
            }
            let status = supervisor.status();
            assert_eq!(status.mounts, 3);
            assert_eq!(status.unmounts, 3);
            assert_eq!(status.changes, 6);
            drop(supervisor);
            let _ = std::fs::remove_dir_all(&home);
        });
    }
}
