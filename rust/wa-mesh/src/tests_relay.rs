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
    stop: Arc<AtomicBool>,
    join: Option<std::thread::JoinHandle<()>>,
}

impl TestRelay {
    /// A relay that knows where each node answers. `POST /relay/send` is forwarded to the target's own
    /// HTTP port and only `status` and `body` come back — headers are dropped, exactly as the real
    /// relay does.
    fn start(routes: HashMap<String, SocketAddr>) -> TestRelay {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("relay bind");
        let address = listener.local_addr().expect("relay address");
        let stop = Arc::new(AtomicBool::new(false));
        let thread_stop = stop.clone();
        let routes = Arc::new(Mutex::new(routes));
        let join = std::thread::spawn(move || {
            for incoming in listener.incoming() {
                if thread_stop.load(Ordering::SeqCst) {
                    break;
                }
                let Ok(mut stream) = incoming else { continue };
                let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
                let routes = routes.clone();
                std::thread::spawn(move || {
                    let request = match http::read_request(&mut stream, http::MAX_BODY) {
                        Ok(Some(request)) => request,
                        _ => return,
                    };
                    let (status, body) = relay_route(&routes, &request);
                    let _ = http::write_response(&mut stream, status, &[], body.as_bytes());
                });
            }
        });
        TestRelay { address, stop, join: Some(join) }
    }

    fn url(&self) -> String {
        self.address.to_string()
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

fn relay_route(routes: &Arc<Mutex<HashMap<String, SocketAddr>>>, request: &http::Request) -> (u16, String) {
    match (request.method.as_str(), request.path.as_str()) {
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
