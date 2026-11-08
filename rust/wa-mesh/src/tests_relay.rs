//! The job's four-node case: the roster decides on the relay path too, and an existing operator
//! bootstraps it.
//!
//! The fleet is Victor's own shape: `a` at level 0 (the operator's machine), `b` at level 1, `t` at
//! level 1 with **no address at all**, and `r` at level 1 with no address either (a node that can only
//! be reached through the relay). `t` is a node that was bound before the mesh existed: it pins the
//! operator list `[b]`, exactly like `nextcloud` pins `[openclaw, wasm_the_first]`, so `a` — the node
//! that legitimately controls everything below it — is refused by the pin list, not by any hierarchy.
//!
//! What is exercised here, in the order a real deployment meets it:
//!
//! 1. `a → t` through the relay is **refused before the push**: `t` has no roster, so today's
//!    operator-pin check decides and it does not know `a`;
//! 2. `b push-roster t` — `b` is already one of `t`'s pinned operators, so `t` accepts the roster,
//!    pins its key and enables it in its own policy (`fleet::PushRequest::install`);
//! 3. `a → t` through the relay is now **allowed**, by the hierarchy, and the answer is signed;
//! 4. `t → a` is refused by the hierarchy (an upward call), *on the target*, and a refusal is never
//!    retried on another path;
//! 5. a relayed call whose body was altered after signing is refused (`bad_signature`, body hash);
//! 6. the same bytes sent twice are refused (`replayed_request`);
//! 7. a node that pins a *different* fleet key refuses the push unless the old key signs the
//!    re-anchoring — no silent re-anchoring.
//!
//! Loopback only, ephemeral ports only, a throwaway temp home per node. The relay here is a test
//! service that forwards a request to the target and hands back its status and body — the same two
//! fields the real relay returns (it drops headers, which is why a relayed answer carries its
//! signature in its body).
use crate::admission::{self, Admission, Admitter, Inbound, NodeFiles};
use crate::audit::MemorySink;
use crate::client::{Client, ClientConfig, Inner, Outcome};
use crate::fleet::PushRequest;
use crate::http;
use crate::identity::Identity;
use crate::policy::MeshPolicy;
use crate::relay::RelayAnswer;
use crate::roster::{Draft, Roster, RosterNode};
use crate::testkit::{self, temp_dir, Member};
use crate::wire::{self, MeshReply};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

const CALL: &str = "call";

// ---------------------------------------------------------------------------------------------------
// The test relay: transport only.
// ---------------------------------------------------------------------------------------------------

struct TestRelay {
    address: SocketAddr,
    /// The path the service is reached at, the way an operator's URL names a relay behind a proxy
    /// (`https://host/fleet`). Empty for the plain root, which is what most of these tests use.
    prefix: String,
    stop: Arc<AtomicBool>,
    join: Option<std::thread::JoinHandle<()>>,
}

impl TestRelay {
    /// A relay that knows where each node answers. `POST /relay/send` is forwarded to the target's own
    /// HTTP port and only `status` and `body` come back — headers are dropped, exactly as the real
    /// relay does.
    fn start(routes: HashMap<String, SocketAddr>) -> TestRelay {
        TestRelay::start_at(routes, "")
    }

    /// The same relay, mounted at `prefix` — how a service behind a reverse proxy is addressed.
    fn start_at(routes: HashMap<String, SocketAddr>, prefix: &str) -> TestRelay {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("relay bind");
        let address = listener.local_addr().expect("relay address");
        let stop = Arc::new(AtomicBool::new(false));
        let thread_stop = stop.clone();
        let routes = Arc::new(Mutex::new(routes));
        let prefix = prefix.trim_end_matches('/').to_string();
        let thread_prefix = prefix.clone();
        let join = std::thread::spawn(move || {
            for incoming in listener.incoming() {
                if thread_stop.load(Ordering::SeqCst) {
                    break;
                }
                let Ok(mut stream) = incoming else { continue };
                let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
                let routes = routes.clone();
                let prefix = thread_prefix.clone();
                std::thread::spawn(move || {
                    let request = match http::read_request(&mut stream, http::MAX_BODY) {
                        Ok(Some(request)) => request,
                        _ => return,
                    };
                    let (status, body) = relay_route(&routes, &prefix, &request);
                    let _ = http::write_response(&mut stream, status, &[], body.as_bytes());
                });
            }
        });
        TestRelay { address, prefix, stop, join: Some(join) }
    }

    /// The address the plan's transport dials: a bare `host:port` when the relay is at the root (the
    /// shape the mesh always used), a **service URL** — scheme, host, path, no explicit port in the live
    /// fleet — when the test is exercising the URL shapes the operator actually writes.
    fn url(&self) -> String {
        if self.prefix.is_empty() {
            self.address.to_string()
        } else {
            format!("http://{}{}", self.address, self.prefix)
        }
    }
}

impl Drop for TestRelay {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        let _ = std::net::TcpStream::connect_timeout(&self.address, Duration::from_millis(250));
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
    }
}

fn relay_route(
    routes: &Arc<Mutex<HashMap<String, SocketAddr>>>,
    prefix: &str,
    request: &http::Request,
) -> (u16, String) {
    // A relay mounted at a prefix is reached at `<prefix>/relay/send`; anything else is not a route.
    let path = request.path.strip_prefix(prefix).unwrap_or_default().to_string();
    match (request.method.as_str(), path.as_str()) {
        ("POST", "/relay/send") => {
            let envelope: Value = match serde_json::from_str(&request.body_text()) {
                Ok(value) => value,
                Err(_) => return (400, json!({"error": "bad_request"}).to_string()),
            };
            let to = envelope["to"].as_str().unwrap_or_default().to_string();
            let Some(target) = routes.lock().ok().and_then(|routes| routes.get(&to).copied()) else {
                return (404, json!({"error": "unknown_node"}).to_string());
            };
            let mut headers = Vec::new();
            if let Some(map) = envelope["headers"].as_object() {
                for (name, value) in map {
                    headers.push((name.clone(), value.as_str().unwrap_or_default().to_string()));
                }
            }
            let method = envelope["method"].as_str().unwrap_or("POST");
            let path = envelope["path"].as_str().unwrap_or("/");
            match http::request(
                &target.to_string(),
                method,
                path,
                &headers,
                envelope["body"].as_str().unwrap_or_default().as_bytes(),
                Duration::from_secs(3),
                Duration::from_secs(20),
                http::MAX_BODY,
            ) {
                Ok(response) => (
                    200,
                    json!({"ok": true, "status": response.status, "body": response.body_text()}).to_string(),
                ),
                Err(error) => (504, json!({"error": "node_no_answer", "detail": error}).to_string()),
            }
        }
        // A long poll with nothing queued, and the acknowledgment of a result: this relay forwards
        // synchronously, so neither is ever needed here.
        ("GET", "/relay/poll") => (200, "{}".into()),
        ("POST", "/relay/respond") => (200, json!({"ok": true}).to_string()),
        _ => (404, json!({"error": "not_found"}).to_string()),
    }
}

// ---------------------------------------------------------------------------------------------------
// A node: today's `/node/call` admission, and the mesh envelope on the same route.
// ---------------------------------------------------------------------------------------------------

struct TestNode {
    address: SocketAddr,
    stop: Arc<AtomicBool>,
    join: Option<std::thread::JoinHandle<()>>,
    audit: Arc<MemorySink>,
}

impl TestNode {
    fn start(_member: &Member, config: PathBuf, pins: Vec<(String, String)>) -> TestNode {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("node bind");
        let address = listener.local_addr().expect("node address");
        let stop = Arc::new(AtomicBool::new(false));
        let thread_stop = stop.clone();
        let audit = Arc::new(MemorySink::new());
        let thread_audit = audit.clone();
        let thread_config = config.clone();
        let pins = Arc::new(Mutex::new(pins));
        let join = std::thread::spawn(move || {
            for incoming in listener.incoming() {
                if thread_stop.load(Ordering::SeqCst) {
                    break;
                }
                let Ok(mut stream) = incoming else { continue };
                let _ = stream.set_read_timeout(Some(Duration::from_secs(15)));
                let config = thread_config.clone();
                let pins = pins.clone();
                let audit = thread_audit.clone();
                std::thread::spawn(move || {
                    let request = match http::read_request(&mut stream, http::MAX_BODY) {
                        Ok(Some(request)) => request,
                        _ => return,
                    };
                    let (status, headers, body) = node_route(&config, &pins, &audit, &request);
                    let _ = http::write_response(&mut stream, status, &headers, body.as_bytes());
                });
            }
        });
        TestNode { address, stop, join: Some(join), audit }
    }

    fn lines(&self) -> Vec<String> {
        self.audit.lines()
    }
}

impl Drop for TestNode {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        let _ = std::net::TcpStream::connect_timeout(&self.address, Duration::from_millis(250));
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
    }
}

type Pins = Arc<Mutex<Vec<(String, String)>>>;

/// The node's own `/node/call` route: the mesh envelope, decided by the roster when this node has one,
/// and today's operator-pin check when it has not.
fn node_route(
    config: &std::path::Path,
    pins: &Pins,
    audit: &Arc<MemorySink>,
    request: &http::Request,
) -> (u16, Vec<(String, String)>, String) {
    if request.path != "/node/call" || request.method != "POST" {
        return (404, Vec::new(), json!({"error": "not_found"}).to_string());
    }
    let identity = Identity::load(&config.join("node.key")).expect("node identity");
    let admitter = Admitter::from_files(
        NodeFiles {
            policy: config.join("policy.json"),
            roster: config.join("mesh-roster.json"),
            config: config.to_path_buf(),
        },
        identity,
        audit.clone(),
    );
    let relayed = admission::carrier(&request.headers) == admission::Transport::Relay;
    let inbound = if relayed {
        Inbound::relayed(request.headers.clone(), request.body_text())
    } else {
        Inbound::direct(request.headers.clone(), request.body_text())
    };
    match admitter.decide(&inbound) {
        Admission::Allow(allowed) => {
            let reply = crate::server::Reply::ok(json!({
                "ran": allowed.call.capability,
                "from": allowed.call.from.name,
                "mesh": true,
                "verb": allowed.verb.as_str(),
                "reason": allowed.verdict.reason,
            })
            .to_string());
            allowed.finish(&reply);
            let mesh_reply = wire::MeshReply {
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
            let identity = Identity::load(&config.join("node.key")).expect("node identity");
            if relayed {
                let answer = RelayAnswer::seal(
                    &identity,
                    &identity.node_id,
                    &allowed.call.from.node_id,
                    &mesh_reply,
                );
                return (200, Vec::new(), answer.encode());
            }
            admission::seal_reply(&identity, &identity.node_id, &allowed.call.from.node_id, &mesh_reply)
        }
        Admission::Refuse { status, headers, body } => (status, headers, body),
        Admission::Legacy { body, headers, why } => {
            let _ = why;
            let identity = Identity::load(&config.join("node.key")).expect("node identity");
            legacy_call(&identity, pins, &body, &headers, relayed)
        }
    }
}

/// Today's path, in miniature: `wa_node_call`'s signature check, then the operator pins of the node's
/// binding, then a signed answer. This is what a node that has never had a roster pushed to it does.
fn legacy_call(
    identity: &Identity,
    pins: &Pins,
    body: &str,
    headers: &[(String, String)],
    relayed: bool,
) -> (u16, Vec<(String, String)>, String) {
    let header = |name: &str| {
        headers
            .iter()
            .find(|(key, _)| key.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.clone())
            .unwrap_or_default()
    };
    let (from, public_key, ts, signature) = (
        header("x-wa-node"),
        header("x-wa-pub"),
        header("x-wa-ts"),
        header("x-wa-sig"),
    );
    let stamp = ts.parse::<u64>().unwrap_or(0);
    let signed = format!("{CALL}|{from}|{stamp}|{}", crate::identity::sha256_hex(body));
    if !crate::identity::verify(&public_key, &signed, &signature) {
        return (200, Vec::new(), json!({"error": "bad_signature"}).to_string());
    }
    if !wire::is_fresh(stamp, wire::now_seconds()) {
        return (200, Vec::new(), json!({"error": "stale_request"}).to_string());
    }
    let pinned = pins
        .lock()
        .map(|pins| pins.iter().any(|(id, key)| id == &from && key == &public_key))
        .unwrap_or(false);
    if !pinned {
        return (200, Vec::new(), json!({"error": "unknown_caller"}).to_string());
    }
    // A pinned caller runs the capability; the answer is signed over the caller's own signature, the
    // way `server.lua`'s `signed_reply` does.
    let reply = json!({"ran": "legacy", "from": from, "mesh": false}).to_string();
    let reply_signature = identity.sign(&format!(
        "reply|{}|{stamp}|{}",
        identity.node_id,
        crate::identity::sha256_hex(&format!("{signature}\n{reply}"))
    ));
    let answer = json!({"reply": reply, "reply_sig": reply_signature}).to_string();
    let _ = relayed;
    (200, Vec::new(), answer)
}

// ---------------------------------------------------------------------------------------------------
// The fleet.
// ---------------------------------------------------------------------------------------------------

struct Fleet {
    fleet_key: Identity,
    roster: Roster,
    a: Member,
    b: Member,
    t: Member,
    r: Member,
}

fn fleet() -> Fleet {
    let fleet_key = testkit::fleet_key();
    let a = Member::new("a", 0, &[]);
    let b = Member::new("b", 1, &[]);
    let t = Member::new("t", 1, &[]);
    let r = Member::new("r", 1, &[]);
    let roster = Draft {
        fleet: "ohana".into(),
        issued_at: wire::now_seconds().saturating_sub(60),
        expires_at: 0,
        nodes: vec![a.node.clone(), b.node.clone(), t.node.clone(), r.node.clone()],
    }
    .sign(&fleet_key);
    Fleet { fleet_key, roster, a, b, t, r }
}

/// A node's own config directory, with its key at `<config>/node.key` and the policy the node runs.
struct NodeDir {
    config: PathBuf,
}

impl NodeDir {
    fn new(member: &Member, policy: Value, roster: Option<&Roster>) -> NodeDir {
        let config = temp_dir(&format!("node-{}", member.node.name));
        std::fs::copy(&member.key_path, config.join("node.key")).expect("node key");
        std::fs::write(
            config.join("policy.json"),
            serde_json::to_string_pretty(&policy).expect("policy json"),
        )
        .expect("policy file");
        if let Some(roster) = roster {
            std::fs::write(
                config.join("mesh-roster.json"),
                serde_json::to_string_pretty(roster).expect("roster json"),
            )
            .expect("roster file");
        }
        NodeDir { config }
    }

    fn pins(&self, member: &Member) -> Vec<(String, String)> {
        vec![(member.node.node_id.clone(), member.node.public_key.clone())]
    }

    fn policy(&self) -> MeshPolicy {
        MeshPolicy::from_policy_file(self.config.join("policy.json")).expect("policy")
    }
}

fn member_policy(roster_key: &str, enabled: bool) -> Value {
    json!({
        "version": 1,
        "components": {},
        "mesh": {"version": 1, "roster_key": roster_key, "enabled": enabled},
    })
}

fn client<'a>(
    identity: &'a Identity,
    roster: &'a Roster,
    policy: &'a MeshPolicy,
    cache: &'a mut crate::cache::PeerCache,
    audit: &'a MemorySink,
    relay: Option<String>,
) -> Client<'a> {
    Client {
        identity,
        roster,
        policy,
        cache,
        audit,
        config: ClientConfig {
            io_timeout: Duration::from_secs(15),
            relay,
            ..ClientConfig::default()
        },
    }
}

fn now() -> u64 {
    wire::now_seconds()
}

#[test]
fn the_roster_decides_on_the_relay_path_too_and_an_existing_operator_bootstraps_it() {
    let _lock = testkit::ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let fleet = fleet();
    let roster_json = serde_json::to_string_pretty(&fleet.roster).unwrap();

    // T is a bound node that pins `b` as its operator (the `nextcloud` shape). It has never seen a
    // roster: its policy names no fleet key, so nothing can be verified and today's rule applies.
    let t_dir = NodeDir::new(&fleet.t, json!({"version": 1, "components": {}}), None);
    let b_dir = NodeDir::new(&fleet.b, member_policy(&fleet.fleet_key.public_key, true), Some(&fleet.roster));
    let a_dir = NodeDir::new(&fleet.a, member_policy(&fleet.fleet_key.public_key, true), Some(&fleet.roster));
    let r_dir = NodeDir::new(&fleet.r, member_policy(&fleet.fleet_key.public_key, true), Some(&fleet.roster));

    let t = TestNode::start(&fleet.t, t_dir.config.clone(), t_dir.pins(&fleet.b));
    let b = TestNode::start(&fleet.b, b_dir.config.clone(), t_dir.pins(&fleet.b));
    let a = TestNode::start(&fleet.a, a_dir.config.clone(), Vec::new());
    let r = TestNode::start(&fleet.r, r_dir.config.clone(), Vec::new());

    let mut routes = HashMap::new();
    routes.insert(fleet.a.node.node_id.clone(), a.address);
    routes.insert(fleet.b.node.node_id.clone(), b.address);
    routes.insert(fleet.t.node.node_id.clone(), t.address);
    routes.insert(fleet.r.node.node_id.clone(), r.address);
    let relay = TestRelay::start(routes);

    // Every fleet member decides by the roster; T does not yet, and its own policy says so.
    let a_policy = a_dir.policy();
    let t_policy = t_dir.policy();
    assert!(admission::in_force(&a_policy));
    assert!(!admission::in_force(&t_policy), "t has not been pushed a roster yet");
    let _ = (&relay, &roster_json);

    // --- 1. a -> t through the relay, refused before the push -------------------------------
    let audit = MemorySink::new();
    let inner = inner_request(&fleet.a, &fleet.t.node, "read");
    let mut cache = crate::cache::PeerCache::empty();
    cache.merge_roster(&fleet.roster, wire::now_millis());
    let mut caller = client(&fleet.a.identity, &fleet.roster, &a_policy, &mut cache, &audit, Some(relay.url()));
    let refused = caller.call("t", "read", json!({"path": "README.md"}), inner.clone());
    match &refused {
        Outcome::Refused { code, verified, .. } => {
            assert_eq!(code, "unknown_caller", "t's operator pins are the authority until it has a roster");
            assert!(!verified, "an unsigned refusal is a diagnosis, never a result");
        }
        other => panic!("a call to a node that pins other operators must be refused: {other:?}"),
    }
    assert!(
        t.lines().iter().any(|line| line.contains("legacy_pins")),
        "t recorded that today's pins decided: {:?}",
        t.lines()
    );

    // --- 2. b push-roster t ----------------------------------------------------------------
    //  b is already a pinned operator of t under today's binding, so t accepts the install. The push
    //  carries only public material: the signed roster and the fleet public key.
    let push = PushRequest {
        config: t_dir.config.to_string_lossy().to_string(),
        roster: roster_json.clone(),
        roster_key: fleet.fleet_key.public_key.clone(),
        caller_node_id: fleet.b.node.node_id.clone(),
        caller_public_key: fleet.b.node.public_key.clone(),
        target_node_id: fleet.t.node.node_id.clone(),
        replace_key_signature: None,
        port: None,
        bind: None,
    };
    let installed = push.install();
    assert_eq!(installed["ok"], true, "{installed}");
    assert_eq!(installed["fleet"], "ohana");
    assert_eq!(installed["roster_key"], fleet.fleet_key.public_key);
    assert!(t_dir.config.join("policy.prev.json").exists(), "the previous policy is kept");
    assert!(t_dir.config.join("mesh-roster.json").exists());
    // The running node now decides by the roster: `mesh.enabled` in its own policy.
    let t_policy = t_dir.policy();
    assert!(t_policy.enabled);
    assert!(admission::in_force(&t_policy));

    // --- 3. a -> t through the relay is now allowed, by the hierarchy ----------------------
    let mut caller = client(&fleet.a.identity, &fleet.roster, &a_policy, &mut cache, &audit, Some(relay.url()));
    match caller.call("t", "read", json!({"path": "README.md"}), inner.clone()) {
        Outcome::Ok { node, verdict, transport, body, .. } => {
            assert_eq!(node.name, "t");
            assert_eq!(transport, "relay", "there is no address for t: the relay carried it");
            assert_eq!(verdict.reason, "hierarchy_allowed");
            let answer: Value = serde_json::from_str(&body).expect("target body");
            assert_eq!(answer["mesh"], true, "the roster decided, not the pins: {answer}");
            assert_eq!(answer["from"], "a");
        }
        other => panic!("a level-0 node may call a level-1 node once the roster is installed: {other:?}"),
    }
    assert!(
        t.lines().iter().any(|line| line.contains("reason=hierarchy_allowed")),
        "the target audited the decision: {:?}",
        t.lines()
    );

    // --- 4. t -> a is refused by the hierarchy, and a refusal is never retried --------------
    let t_policy = t_dir.policy();
    let mut upward = client(&fleet.t.identity, &fleet.roster, &t_policy, &mut cache, &audit, Some(relay.url()));
    let denied = upward.call("a", "bash", json!({"command": "uptime"}), Inner::default()).to_json();
    assert_eq!(denied["error"], "mesh_denied");
    assert_eq!(denied["reason"], "hierarchy_denied");
    assert!(denied["fallback"].is_null(), "a denial must not offer another path: {denied}");
    // The target's copy would refuse it too (both ends run the same rule).
    let mut t_as_b = client(&fleet.t.identity, &fleet.roster, &t_policy, &mut cache, &audit, Some(relay.url()));
    let _ = t_as_b.call("b", "read", json!({}), Inner::default());

    // --- 5. a relayed call whose bytes were altered after signing --------------------------
    //  The envelope is the same signed call the direct path sends; its signature covers the hash of the
    //  body, so `read` cannot be turned into `bash` on the way through the relay.
    let (body, headers) = signed_mesh_call(&fleet.a, &fleet.t.node, "read", "tamper");
    let altered = body.replace("\"capability\":\"read\"", "\"capability\":\"bash\"");
    assert_ne!(altered, body);
    let relayed = relay_send(&relay, &fleet.t.node.node_id, &fleet.a.identity, &headers, &altered, "tamper");
    assert_eq!(relayed["ok"], true, "the relay carried it: {relayed}");
    assert_ne!(relayed["status"], 200, "a tampered envelope is not accepted: {relayed}");
    let answer: Value = serde_json::from_str(relayed["body"].as_str().unwrap()).unwrap();
    assert_eq!(answer["error"], "bad_signature", "{answer}");

    // --- 6. the same bytes twice ------------------------------------------------------------
    let (body, headers) = signed_mesh_call(&fleet.a, &fleet.t.node, "read", "replay-me");
    let first = relay_send(&relay, &fleet.t.node.node_id, &fleet.a.identity, &headers, &body, "replay-me");
    let first_text = first["body"].as_str().expect("relay body");
    let first_reply = RelayAnswer::open(
        first_text,
        &fleet.t.node.node_id,
        &fleet.t.node.public_key,
        &fleet.a.node.node_id,
        now(),
    )
    .expect("the target's signed answer opens");
    assert!(first_reply.ok, "{first_reply:?}");
    let second = relay_send(&relay, &fleet.t.node.node_id, &fleet.a.identity, &headers, &body, "replay-me");
    let second: Value = serde_json::from_str(second["body"].as_str().unwrap()).unwrap();
    assert_eq!(second["error"], "replayed_request", "{second}");

    // --- 7. a target that pins a different fleet key refuses the push -----------------------
    let other_key = testkit::fleet_key();
    let other_dir = NodeDir::new(
        &fleet.r,
        member_policy(&other_key.public_key, true),
        None,
    );
    let mut wrong = PushRequest {
        config: other_dir.config.to_string_lossy().to_string(),
        roster: roster_json.clone(),
        roster_key: fleet.fleet_key.public_key.clone(),
        caller_node_id: fleet.b.node.node_id.clone(),
        caller_public_key: fleet.b.node.public_key.clone(),
        target_node_id: fleet.r.node.node_id.clone(),
        replace_key_signature: None,
        port: None,
        bind: None,
    };
    assert_eq!(wrong.install()["error"], "roster_pins_different_key");
    // The old key's signature re-anchors it; nothing else does.
    let message = format!(
        "{}|{}|{}",
        crate::fleet::ANCHOR_DOMAIN,
        fleet.fleet_key.public_key,
        fleet.roster.fingerprint()
    );
    // A signature by any key other than the one this node pins *now* is refused.
    wrong.replace_key_signature = Some(fleet.fleet_key.sign(&message));
    assert_eq!(wrong.install()["error"], "roster_replace_key_unverified");
    // The pinned key over a different statement is refused as well.
    wrong.replace_key_signature = Some(other_key.sign("mesh-anchor-v1|someone-else|0000000000000000"));
    assert_eq!(wrong.install()["error"], "roster_replace_key_unverified");
    // The pinned key over exactly this statement re-anchors the node, and says what it replaced.
    wrong.replace_key_signature = Some(other_key.sign(&message));
    let anchored = wrong.install();
    assert_eq!(anchored["ok"], true, "{anchored}");
    assert_eq!(anchored["previous_key"], other_key.public_key);
    assert_eq!(anchored["roster_key"], fleet.fleet_key.public_key);

    let _ = (&fleet.fleet_key, &fleet.r);
}

/// The caller's own `/node/call` request, signed the way `nodes.lua` signs one: `call|node|ts|sha256`.
/// The mesh envelope carries it verbatim, which is what lets a node without a roster run it under
/// today's admission (its operator pins) instead of refusing the call outright.
fn inner_request(caller: &Member, to: &RosterNode, capability: &str) -> Inner {
    let body = json!({
        "from_node_id": caller.node.node_id,
        "to_node_id": to.node_id,
        "request_id": "inner-1",
        "capability": capability,
        "args": {"path": "README.md"},
    })
    .to_string();
    let ts = now();
    let message = format!(
        "{CALL}|{}|{ts}|{}",
        caller.node.node_id,
        crate::identity::sha256_hex(&body)
    );
    let signature = caller.identity.sign(&message);
    Inner {
        body,
        headers: vec![
            ("X-WA-Node".to_string(), caller.node.node_id.clone()),
            ("X-WA-Pub".to_string(), caller.node.public_key.clone()),
            ("X-WA-Ts".to_string(), ts.to_string()),
            ("X-WA-Sig".to_string(), signature),
        ],
    }
}

/// A signed mesh envelope, built by hand so a test can be a caller the client would never be.
fn signed_mesh_call(
    caller: &Member,
    to: &RosterNode,
    capability: &str,
    request_id: &str,
) -> (String, Vec<(String, String)>) {
    let envelope = wire::MeshCall {
        schema: wire::SCHEMA,
        request_id: request_id.into(),
        from_node_id: caller.node.node_id.clone(),
        to_node_id: to.node_id.clone(),
        capability: capability.into(),
        args: json!({"path": "README.md"}),
        inner_body: json!({
            "from_node_id": caller.node.node_id,
            "to_node_id": to.node_id,
            "capability": capability,
            "args": {"path": "README.md"},
        })
        .to_string(),
        inner_headers: Vec::new(),
    };
    let body = envelope.encode();
    let ts = now();
    let signature = caller.identity.sign(&wire::MeshCall::call_message(&caller.node.node_id, ts, &body));
    let headers = vec![
        ("x-wa-mesh".to_string(), "1".to_string()),
        (crate::admission::CARRIER_HEADER.to_string(), "relay".to_string()),
        ("content-type".to_string(), "application/json".to_string()),
        ("x-wa-node".to_string(), caller.node.node_id.clone()),
        ("x-wa-pub".to_string(), caller.node.public_key.clone()),
        ("x-wa-ts".to_string(), ts.to_string()),
        ("x-wa-sig".to_string(), signature),
    ];
    (body, headers)
}

/// Ask the test relay to carry one request, exactly as the real one does (`/relay/send`).
fn relay_send(
    relay: &TestRelay,
    to_node_id: &str,
    identity: &Identity,
    headers: &[(String, String)],
    body: &str,
    rid: &str,
) -> Value {
    let header_map: serde_json::Map<String, Value> = headers
        .iter()
        .map(|(name, value)| (name.clone(), Value::String(value.clone())))
        .collect();
    let envelope = json!({
        "rid": rid, "to": to_node_id, "method": "POST", "path": "/node/call",
        "headers": header_map, "body": body,
    })
    .to_string();
    let ts = now().to_string();
    let signature = identity.sign(&format!("relay-send|{}|{ts}", identity.node_id));
    let response = http::request(
        &relay.url(),
        "POST",
        "/relay/send",
        &[
            ("x-wa-node".to_string(), identity.node_id.clone()),
            ("x-wa-pub".to_string(), identity.public_key.clone()),
            ("x-wa-ts".to_string(), ts),
            ("x-wa-sig".to_string(), signature),
        ],
        envelope.as_bytes(),
        Duration::from_secs(3),
        Duration::from_secs(20),
        http::MAX_BODY,
    )
    .expect("the relay answers");
    serde_json::from_str(&response.body_text()).expect("relay answer")
}

#[test]
fn the_relay_answer_carries_the_targets_signature_so_a_forged_relay_cannot_answer() {
    // The relay sees the reply body. Without a signature inside it, a relay (or anything else that
    // can write that field) could answer for the target. This is the check the client performs.
    let fleet = fleet();
    let target = fleet.t.reload();
    let reply = MeshReply {
        schema: wire::SCHEMA,
        request_id: "r1".into(),
        from_node_id: fleet.t.node.node_id.clone(),
        ok: true,
        status: Some(200),
        body: Some("{\"ran\":\"read\"}".into()),
        error: None,
        reason: None,
        detail: None,
        verb: Some("read".into()),
    };
    let sealed = RelayAnswer::seal(
        &target,
        &fleet.t.node.node_id,
        &fleet.a.node.node_id,
        &reply,
    );
    let opened = RelayAnswer::open(
        &sealed.encode(),
        &fleet.t.node.node_id,
        &fleet.t.node.public_key,
        &fleet.a.node.node_id,
        sealed.ts,
    )
    .expect("the target's own answer opens");
    assert_eq!(opened, reply);
    // The relay re-writes the reply inside the body: refused, because the signature covers its hash.
    let mut envelope: Value = serde_json::from_str(&sealed.encode()).expect("answer envelope");
    let reply_text = envelope["reply"].as_str().expect("reply text").replace("read", "bash");
    envelope["reply"] = Value::String(reply_text);
    let forged = envelope.to_string();
    assert!(RelayAnswer::open(
        &forged,
        &fleet.t.node.node_id,
        &fleet.t.node.public_key,
        &fleet.a.node.node_id,
        sealed.ts
    )
    .is_err());
}

// ---------------------------------------------------------------------------------------------------
// The two live blockers of 07/11, end to end on loopback.
// ---------------------------------------------------------------------------------------------------

/// The caller's home: a node key, the operator's own `policy.json`, and the signed roster beside it.
/// Nothing else — in particular no `WA_MESH` anywhere: the whole statement is the file.
fn caller_home(member: &Member, roster: &Roster, fleet_key: &str, enabled: bool) -> PathBuf {
    let home = temp_dir(&format!("home-{}", member.node.name));
    let config = home.join(".wasm-agent");
    std::fs::create_dir_all(&config).expect("config dir");
    std::fs::copy(&member.key_path, config.join("node.key")).expect("node key");
    std::fs::write(
        config.join("policy.json"),
        json!({
            "version": 1,
            "components": {},
            "mesh": {"version": 1, "roster_key": fleet_key, "enabled": enabled,
                     "roster": "mesh-roster.json"},
        })
        .to_string(),
    )
    .expect("policy");
    std::fs::write(
        config.join("mesh-roster.json"),
        serde_json::to_string_pretty(roster).expect("roster json"),
    )
    .expect("roster");
    home
}

/// `host.mesh_call`'s request for one peer call, built the way `lua/core/nodes.lua` builds it: the
/// caller's own `/node/call` request and headers travel inside the envelope.
fn dispatch_request(caller: &Member, to: &RosterNode, capability: &str) -> Value {
    let inner = inner_request(caller, to, capability);
    json!({
        "node": to.node_id,
        "capability": capability,
        "args": {"path": "README.md"},
        "inner_body": inner.body,
        "inner_headers": inner
            .headers
            .iter()
            .map(|(name, value)| json!([name, value]))
            .collect::<Vec<Value>>(),
        "timeout_seconds": 15,
    })
}

/// The 07/11 rollout, in one test: a caller whose **`policy.json` alone** enables the mesh (nothing in
/// its environment), a relay reached at a **service URL with a scheme and a path and no explicit port**
/// in the URL's shape, and a target **bound with operator pins that do not include the caller**.
///
/// In order: the caller's gate answers *on, from the policy*; the call reaches the target through the
/// relay and is refused by the target's pins (`unknown_caller`, unsigned — the pre-bootstrap state);
/// `b` pushes the roster (it is a pinned operator, nothing else could); the **same** call, from the
/// same caller, is now admitted by the roster through the relay; and a caller whose policy says nothing
/// is unchanged — `mesh_disabled`, the legacy path exactly as before.
#[test]
fn a_caller_enabled_only_by_its_policy_reaches_the_roster_through_a_service_url() {
    testkit::with_deadline(
        "a_caller_enabled_only_by_its_policy_reaches_the_roster_through_a_service_url",
        || {
            let _lock = testkit::ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            let fleet = fleet();
            let roster_json = serde_json::to_string_pretty(&fleet.roster).expect("roster json");

            // T is the node that was bound before the mesh existed, pinning `b` and nobody else.
            let t_dir = NodeDir::new(&fleet.t, json!({"version": 1, "components": {}}), None);
            let t = TestNode::start(&fleet.t, t_dir.config.clone(), t_dir.pins(&fleet.b));
            let mut routes = HashMap::new();
            routes.insert(fleet.t.node.node_id.clone(), t.address);
            // The relay as an operator's URL names it: a service at a path, not at the root. The scheme
            // and the path are what `crate::endpoint` has to carry; the port is explicit here because a
            // test may not bind 80 (`crate::endpoint`'s own tests cover the default-port mapping).
            let relay = TestRelay::start_at(routes, "/fleet");

            // The caller: a level-0 node whose own policy is the whole statement.
            let home = caller_home(&fleet.a, &fleet.roster, &fleet.fleet_key.public_key, true);
            let config = home.join(".wasm-agent");
            let _env = testkit::EnvGuard::set(&[
                ("WASM_AGENT_HOME", Some(home.to_str().expect("utf8 home"))),
                ("WASM_AGENT_NODE_KEY", None),
                ("WA_GRANT_POLICY", None),
                ("WASM_AGENT_MESH_ROSTER", None),
                ("WASM_AGENT_MESH_CACHE", None),
                ("WASM_AGENT_MESH_PORT", None),
                ("WASM_AGENT_RELAY", Some(relay.url().as_str())),
                ("WA_MESH", None),
                ("WASM_AGENT_MESH", None),
            ]);
            crate::gate::reset_cache();

            // --- 1. the gate: on, and the policy is why (no flag anywhere on this node) -----------
            let gate = crate::host_call::dispatch(&json!({"gate": true}));
            assert_eq!(gate["ok"], true, "{gate}");
            assert_eq!(gate["enabled"], true, "policy.json alone enables the caller: {gate}");
            assert_eq!(gate["from"], "policy.json mesh.enabled", "{gate}");
            assert!(gate["problem"].is_null());

            // --- 2. before the push: the relay carries it, the target's pins refuse it -------------
            let request = dispatch_request(&fleet.a, &fleet.t.node, "read");
            let refused = crate::host_call::dispatch(&request);
            assert_eq!(refused["ok"], false, "{refused}");
            assert_eq!(refused["error"], "mesh_refused", "{refused}");
            assert_eq!(
                refused["code"], "unknown_caller",
                "a node bound before the mesh decides by its pins until it is bootstrapped: {refused}"
            );
            assert_eq!(refused["verified"], false, "an unsigned refusal is a diagnosis: {refused}");

            // --- 3. b push-roster t (b is one of t's pinned operators) ------------------------------
            let installed = PushRequest {
                config: t_dir.config.to_string_lossy().to_string(),
                roster: roster_json.clone(),
                roster_key: fleet.fleet_key.public_key.clone(),
                caller_node_id: fleet.b.node.node_id.clone(),
                caller_public_key: fleet.b.node.public_key.clone(),
                target_node_id: fleet.t.node.node_id.clone(),
                replace_key_signature: None,
                port: None,
                bind: None,
            }
            .install();
            assert_eq!(installed["ok"], true, "{installed}");

            // --- 4. the same call, same caller, same URL: the roster admits it through the relay -----
            let allowed = crate::host_call::dispatch(&request);
            assert_eq!(allowed["ok"], true, "a policy-enabled caller is admitted by the roster: {allowed}");
            assert_eq!(allowed["transport"], "relay", "t has no address: the relay carried it: {allowed}");
            assert_eq!(allowed["reason"], "hierarchy_allowed", "{allowed}");
            assert_eq!(allowed["verified"], true, "{allowed}");
            let body: Value = serde_json::from_str(allowed["body"].as_str().expect("a body")).expect("json body");
            assert_eq!(body["mesh"], true, "the roster decided on the target, not the pins: {body}");
            assert_eq!(body["from"], "a");
            assert_eq!(body["verb"], "read");

            // --- 5. a caller whose policy says nothing is unchanged --------------------------------
            //  The same home, turned back off in the operator's own file: the gate says off and the
            //  capability answers `mesh_disabled`, exactly as it did before the mesh existed. The legacy
            //  path itself is untouched too: a plain `/node/call` is refused by t's pins, unsigned.
            std::fs::write(
                config.join("policy.json"),
                json!({"version": 1, "components": {}}).to_string(),
            )
            .expect("policy off");
            crate::gate::reset_cache();
            let off = crate::host_call::dispatch(&json!({"gate": true}));
            assert_eq!(off["enabled"], false, "{off}");
            assert_eq!(off["from"], "default off", "{off}");
            assert_eq!(
                crate::host_call::dispatch(&request)["error"],
                "mesh_disabled",
                "with nothing written, the mesh is off and nothing is dialled"
            );
            let inner = inner_request(&fleet.a, &fleet.t.node, "read");
            let legacy = http::request(
                &t.address.to_string(),
                "POST",
                "/node/call",
                &inner.headers,
                inner.body.as_bytes(),
                testkit::CONNECT_TIMEOUT,
                testkit::SOCKET_DEADLINE,
                http::MAX_BODY,
            )
            .expect("t answers its own route");
            let legacy_body: Value = serde_json::from_str(&legacy.body_text()).expect("legacy body");
            assert_eq!(
                legacy_body["error"], "unknown_caller",
                "the legacy path is exactly what it was: t's pins do not know a: {legacy_body}"
            );

            crate::gate::reset_cache();
        },
    );
}


// ---------------------------------------------------------------------------------------------------
// The execution trust basis (docs/MESH.md §9 item 2).
// ---------------------------------------------------------------------------------------------------

/// The caller's own `/node/call` request with a nonce, so two calls in one second are different bytes
/// (Ed25519 is deterministic, and the replay guard refuses a byte-identical request twice).
fn inner_request_nonce(caller: &Member, to: &RosterNode, capability: &str, nonce: &str) -> Inner {
    let body = json!({
        "from_node_id": caller.node.node_id,
        "to_node_id": to.node_id,
        "request_id": format!("inner-{nonce}"),
        "capability": capability,
        "args": {"path": "README.md", "nonce": nonce},
    })
    .to_string();
    let ts = now();
    let signature = caller
        .identity
        .sign(&format!("{CALL}|{}|{ts}|{}", caller.node.node_id, crate::identity::sha256_hex(&body)));
    Inner {
        body,
        headers: vec![
            ("X-WA-Node".to_string(), caller.node.node_id.clone()),
            ("X-WA-Pub".to_string(), caller.node.public_key.clone()),
            ("X-WA-Ts".to_string(), ts.to_string()),
            ("X-WA-Sig".to_string(), signature),
        ],
    }
}

/// A mesh envelope that carries a real inner request *with its signed headers*, which is what the mount
/// binds the attestation to (`attest::caller_signature` reads `x-wa-sig` out of them).
fn envelope_with_inner(
    caller: &Member,
    to: &RosterNode,
    capability: &str,
    nonce: &str,
) -> (String, Vec<(String, String)>) {
    let inner = inner_request_nonce(caller, to, capability, nonce);
    let envelope = wire::MeshCall {
        schema: wire::SCHEMA,
        request_id: format!("mesh-{nonce}"),
        from_node_id: caller.node.node_id.clone(),
        to_node_id: to.node_id.clone(),
        capability: capability.into(),
        args: json!({"path": "README.md", "nonce": nonce}),
        inner_body: inner.body,
        inner_headers: inner.headers,
    };
    let body = envelope.encode();
    let ts = now();
    let signature = caller
        .identity
        .sign(&wire::MeshCall::call_message(&caller.node.node_id, ts, &body));
    let headers = vec![
        ("x-wa-mesh".to_string(), "1".to_string()),
        (crate::admission::CARRIER_HEADER.to_string(), "relay".to_string()),
        ("content-type".to_string(), "application/json".to_string()),
        ("x-wa-node".to_string(), caller.node.node_id.clone()),
        ("x-wa-pub".to_string(), caller.node.public_key.clone()),
        ("x-wa-ts".to_string(), ts.to_string()),
        ("x-wa-sig".to_string(), signature),
    ];
    (body, headers)
}

/// Four local nodes: `work` at level 0 calls `cloud` at level 2, and `cloud`'s operator pins name
/// `mail` and **not** the caller — the live fleet's shape (`work` → `nextcloud`). What makes the call
/// executable on `cloud` is the attestation its own mount signed, not its pins.
///
/// The Rust half of that seam is measured here: the mount decides ALLOW on the relay path over real
/// loopback sockets, and the attestation it signs is bound to the caller id, the verb, the capability
/// and the caller's own request signature, is fresh only inside `attest::TTL_SECONDS`, and verifies for
/// nothing else. The accepting half is `wa_node_call`'s `verify_peer` (Lua) and is measured by
/// `scripts/test-mesh-trust.lua` against this same byte-for-byte signed message.
#[test]
fn the_target_executes_on_the_mounts_attestation_not_on_its_operators_pins() {
    let fleet_key = testkit::fleet_key();
    let work = Member::new("trust-work", 0, &[]); // the caller: level 0
    let cloud = Member::new("trust-cloud", 2, &[]); // the target: level 2
    let mail = Member::new("trust-mail", 2, &[]); // another level-2 node, and cloud's operator
    let hub = Member::new("trust-hub", 1, &[]);
    let roster = Draft {
        fleet: "ohana".into(),
        issued_at: wire::now_seconds().saturating_sub(60),
        expires_at: 0,
        nodes: vec![work.node.clone(), cloud.node.clone(), mail.node.clone(), hub.node.clone()],
    }
    .sign(&fleet_key);
    let mut ids = std::collections::BTreeSet::new();
    for member in [&work, &cloud, &mail, &hub] {
        assert!(ids.insert(member.node.node_id.clone()), "four distinct local nodes");
    }

    let work_dir = NodeDir::new(&work, member_policy(&fleet_key.public_key, true), Some(&roster));
    let cloud_dir = NodeDir::new(&cloud, member_policy(&fleet_key.public_key, true), Some(&roster));
    let mail_dir = NodeDir::new(&mail, member_policy(&fleet_key.public_key, true), Some(&roster));
    let hub_dir = NodeDir::new(&hub, member_policy(&fleet_key.public_key, true), Some(&roster));

    // The target pins one operator, and it is not the caller: the `nextcloud` shape.
    let cloud_pins = cloud_dir.pins(&mail);
    assert!(
        cloud_pins.iter().all(|(id, _)| id != &work.node.node_id),
        "the target's pins must exclude the caller for this test to mean anything"
    );

    let w = TestNode::start(&work, work_dir.config.clone(), Vec::new());
    let c = TestNode::start(&cloud, cloud_dir.config.clone(), cloud_pins.clone());
    let m = TestNode::start(&mail, mail_dir.config.clone(), Vec::new());
    let h = TestNode::start(&hub, hub_dir.config.clone(), Vec::new());
    let mut routes = HashMap::new();
    routes.insert(work.node.node_id.clone(), w.address);
    routes.insert(cloud.node.node_id.clone(), c.address);
    routes.insert(mail.node.node_id.clone(), m.address);
    routes.insert(hub.node.node_id.clone(), h.address);
    let relay = TestRelay::start(routes);

    // --- 1. level 0 -> level 2, `bash`, carried by the relay and executed ---------------------
    let (body, headers) = envelope_with_inner(&work, &cloud.node, "bash", "allow");
    let carried = relay_send(&relay, &cloud.node.node_id, &work.identity, &headers, &body, "trust-allow");
    assert_eq!(carried["ok"], true, "the relay carried it: {carried}");
    let sealed = carried["body"].as_str().expect("the relay hands back a body");
    let reply = RelayAnswer::open(
        sealed,
        &cloud.node.node_id,
        &cloud.node.public_key,
        &work.node.node_id,
        now(),
    )
    .expect("the target's own signature opens the answer");
    assert!(reply.ok, "the roster admitted a level-0 caller to a level-2 target: {reply:?}");
    assert_eq!(reply.verb.as_deref(), Some("control"));
    let ran: Value = serde_json::from_str(reply.body.as_deref().unwrap_or("{}")).expect("answer body");
    assert_eq!(ran["ran"], "bash", "the capability the caller asked for is the one that ran: {ran}");
    assert_eq!(ran["from"], "trust-work");
    assert_eq!(ran["mesh"], true, "the roster decided, not the pins: {ran}");
    assert!(
        c.lines().iter().any(|line| line.contains("reason=hierarchy_allowed")),
        "the target audited the decision it executed on: {:?}",
        c.lines()
    );

    // --- 2. the proof the target's own admission executes on ----------------------------------
    // Built the way the mount builds it (`admit_inbound`, `LoopbackHandler`): the node's own key, the
    // caller, the verb the roster decided, the capability, and the caller's request signature.
    let proof_inner = inner_request_nonce(&work, &cloud.node, "bash", "proof");
    let (body_a, headers_a) = envelope_with_inner(&work, &cloud.node, "bash", "proof");
    let admitter = Admitter::from_files(
        NodeFiles {
            policy: cloud_dir.config.join("policy.json"),
            roster: cloud_dir.config.join("mesh-roster.json"),
            config: cloud_dir.config.clone(),
        },
        Identity::load(&cloud_dir.config.join("node.key")).expect("cloud identity"),
        Arc::new(MemorySink::new()),
    );
    let allowed = match admitter.decide(&Inbound::relayed(headers_a, body_a)) {
        Admission::Allow(allowed) => allowed,
        other => {
            let _ = other;
            panic!("the roster allows a level-0 node to control a level-2 one");
        }
    };
    assert_eq!(allowed.verdict.reason, "hierarchy_allowed");
    assert_eq!(
        allowed.call.from.node_id, work.node.node_id,
        "the caller the pins exclude is the one the roster allowed"
    );
    let caller_signature = crate::attest::caller_signature(&allowed.call.inner.headers);
    let sent_signature = proof_inner
        .headers
        .iter()
        .find(|(name, _)| name.eq_ignore_ascii_case("x-wa-sig"))
        .map(|(_, value)| value.clone())
        .unwrap_or_default();
    assert_eq!(
        caller_signature, sent_signature,
        "the attestation binds the caller's own request signature"
    );
    let ts = wire::now_seconds();
    let attestation = crate::attestation::sign(
        &Identity::load(&cloud_dir.config.join("node.key")).expect("cloud identity"),
        &work.node.node_id,
        allowed.verb.as_str(),
        &allowed.call.capability,
        &caller_signature,
        ts,
    );
    let signed = crate::attest::message(
        &cloud.node.node_id,
        &work.node.node_id,
        "control",
        "bash",
        &caller_signature,
        ts,
    );
    let signature = attestation["signature"].as_str().expect("signature").to_string();
    assert!(
        crate::identity::verify(&cloud.node.public_key, &signed, &signature),
        "the target's own key signed it"
    );
    assert_eq!(attestation["caller"], work.node.node_id);
    assert_eq!(attestation["verb"], "control");
    assert_eq!(attestation["capability"], "bash");
    assert!(crate::attest::is_fresh(ts, ts), "minted now, spent now");
    assert!(
        !crate::attest::is_fresh(ts, ts + crate::attest::TTL_SECONDS + 1),
        "past `attest::TTL_SECONDS` it proves nothing"
    );
    // Every part is bound: another verb, capability, caller, request or second verifies for nothing.
    for other in [
        crate::attest::message(&cloud.node.node_id, &work.node.node_id, "read", "bash", &caller_signature, ts),
        crate::attest::message(&cloud.node.node_id, &work.node.node_id, "control", "read", &caller_signature, ts),
        crate::attest::message(&cloud.node.node_id, &mail.node.node_id, "control", "bash", &caller_signature, ts),
        crate::attest::message(&cloud.node.node_id, &work.node.node_id, "control", "bash", "some-other-request", ts),
        crate::attest::message(&cloud.node.node_id, &work.node.node_id, "control", "bash", &caller_signature, ts + 1),
    ] {
        assert!(!crate::identity::verify(&cloud.node.public_key, &other, &signature), "{other}");
    }
    // A forged one (the holder edits what the target signed) proves nothing either.
    let flipped = format!("{}{}", if signature.starts_with('0') { "1" } else { "0" }, &signature[1..]);
    assert!(!crate::identity::verify(&cloud.node.public_key, &signed, &flipped));

    // --- 3. level 2 -> level 0 is still denied, on the target --------------------------------
    let (up_body, up_headers) = envelope_with_inner(&mail, &work.node, "bash", "upward");
    let upward = relay_send(&relay, &work.node.node_id, &mail.identity, &up_headers, &up_body, "trust-upward");
    assert_eq!(upward["ok"], true, "the relay carried it: {upward}");
    let upward_reply = RelayAnswer::open(
        upward["body"].as_str().expect("relay body"),
        &work.node.node_id,
        &work.node.public_key,
        &mail.node.node_id,
        now(),
    )
    .expect("the target's signed refusal opens");
    assert!(!upward_reply.ok, "a level-2 node may not call upward to level 0: {upward_reply:?}");
    assert_eq!(upward_reply.error.as_deref(), Some("mesh_denied"));
    assert_eq!(upward_reply.reason.as_deref(), Some("hierarchy_denied"));

    // --- 4. the same request twice: a replayed proof is not a second call --------------------
    let (replay_body, replay_headers) = envelope_with_inner(&work, &cloud.node, "bash", "replay");
    let first = relay_send(&relay, &cloud.node.node_id, &work.identity, &replay_headers, &replay_body, "trust-replay");
    assert_eq!(first["ok"], true);
    let second = relay_send(&relay, &cloud.node.node_id, &work.identity, &replay_headers, &replay_body, "trust-replay");
    let second_body: Value = serde_json::from_str(second["body"].as_str().unwrap()).unwrap();
    assert_eq!(second_body["error"], "replayed_request", "{second_body}");

    // --- 5. no roster: the mesh does not decide, and today's pins are unchanged ---------------
    let plain_dir = NodeDir::new(&hub, json!({"version": 1, "components": {}}), None);
    let no_roster = Admitter::from_files(
        NodeFiles {
            policy: plain_dir.config.join("policy.json"),
            roster: plain_dir.config.join("mesh-roster.json"),
            config: plain_dir.config.clone(),
        },
        Identity::load(&plain_dir.config.join("node.key")).expect("hub identity"),
        Arc::new(MemorySink::new()),
    );
    let from_work = inner_request_nonce(&work, &hub.node, "bash", "no-roster");
    match no_roster.decide(&Inbound::direct(from_work.headers.clone(), from_work.body.clone())) {
        Admission::Legacy { why, .. } => assert_eq!(why, "not_mesh", "a plain peer call is not the mesh's"),
        _ => panic!("a call without a mesh envelope is never decided by the roster"),
    }
    let pins = Arc::new(Mutex::new(cloud_pins.clone()));
    let legacy = legacy_call(
        &Identity::load(&plain_dir.config.join("node.key")).expect("hub identity"),
        &pins,
        &from_work.body,
        &from_work.headers,
        true,
    );
    let legacy_body: Value = serde_json::from_str(&legacy.2).expect("legacy body");
    assert_eq!(
        legacy_body["error"], "unknown_caller",
        "the operator pins are what executed calls before this change, and they still are without a roster: {legacy_body}"
    );

    let _ = (&relay, &w, &c, &m, &h);
}
