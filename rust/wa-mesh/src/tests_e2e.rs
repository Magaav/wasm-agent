//! The end-to-end tests the job asks for: three nodes at levels 0/1/1 and a test rendezvous.
//!
//! Loopback only, ephemeral ports only, identities in the system temp directory only. Nothing here
//! can reach the real fabric, the real rendezvous or a node home, and no test binds 8799, 8800 or
//! 8890.
//!
//! The fleet is the one that exists: `laptop` at level 0, `oracle` and `phone` at level 1. The roster
//! carries identities and levels and **no addresses at all** — addresses come from a rendezvous, are
//! cached, and the rendezvous is then killed. Every call after that must still work, which is the
//! whole point of the peer cache.
use crate::audit::{MemorySink, Sink};
use crate::cache::PeerCache;
use crate::client::{Client, ClientConfig, Inner, Outcome};
use crate::hierarchy::Verb;
use crate::http;
use crate::identity::Identity;
use crate::policy::MeshPolicy;
use crate::roster::{Roster, RosterNode};
use crate::server::{Call as MeshCall, Handler, Reply, Server, ServerConfig};
use crate::testkit::{self, Member};
use crate::wire::{self, MeshCall as Envelope, MeshReply};
use serde_json::{json, Value};
use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

/// Answers with what it was asked, so a passing call is evidence the capability reached the target.
struct Echo;

impl Handler for Echo {
    fn handle(&self, call: &MeshCall) -> Reply {
        Reply::ok(
            json!({
                "echo": call.capability,
                "from": call.from.name,
                "to": call.to.name,
                "args": call.args,
                "request_id": call.request_id,
                "verb": call.verb.as_str(),
                "inner_body": call.inner.body,
                "inner_headers": call.inner.headers.iter()
                    .map(|(name, value)| format!("{name}: {value}"))
                    .collect::<Vec<_>>(),
            })
            .to_string(),
        )
    }
}

struct Fleet {
    fleet_key: Identity,
    roster: Roster,
    /// The operator's policy with the fleet key pinned and no grants: the hierarchy and nothing else.
    policy: MeshPolicy,
    laptop: Member,
    oracle: Member,
    phone: Member,
    laptop_server: Server,
    oracle_server: Server,
    phone_server: Server,
}

fn fleet() -> Fleet {
    fleet_with_grants(false)
}

/// The same fleet, optionally with the operator's grant that lets the oracle drive the laptop.
fn fleet_with_grants(granted: bool) -> Fleet {
    let fleet_key = testkit::fleet_key();
    // Levels are assigned in the roster and nowhere else: 0 is the laptop Victor uses, 1 is the
    // always-on node and the phone.
    let laptop = Member::new("laptop", 0, &[]);
    let oracle = Member::new("oracle", 1, &[]);
    let phone = Member::new("phone", 1, &[]);
    let roster = testkit::roster_of(
        &fleet_key,
        vec![laptop.node.clone(), oracle.node.clone(), phone.node.clone()],
    );
    let grants = if granted {
        format!(
            r#"[{{"caller":"{}","target":"{}","verb":"control","effect":"allow",
                  "note":"the oracle may drive the laptop"}}]"#,
            oracle.node.node_id, laptop.node.node_id
        )
    } else {
        "[]".to_string()
    };
    let policy = MeshPolicy::from_policy_text(&format!(
        r#"{{"version":1,"mesh":{{"version":1,"roster_key":"{}","grants":{}}}}}"#,
        fleet_key.public_key, grants
    ))
    .expect("operator policy");
    let laptop_server = start(&laptop, &roster, &policy);
    let oracle_server = start(&oracle, &roster, &policy);
    let phone_server = start(&phone, &roster, &policy);
    Fleet {
        fleet_key,
        roster,
        policy,
        laptop,
        oracle,
        phone,
        laptop_server,
        oracle_server,
        phone_server,
    }
}

fn start(member: &Member, roster: &Roster, policy: &MeshPolicy) -> Server {
    let audit: Arc<dyn Sink> = Arc::new(MemorySink::new());
    Server::start(ServerConfig::new(
        "127.0.0.1:0",
        member.reload(),
        roster.clone(),
        policy.clone(),
        Arc::new(Echo),
        audit,
    ))
    .expect("listener")
}

impl Fleet {
    fn addresses(&self) -> Vec<(&RosterNode, SocketAddr)> {
        vec![
            (&self.laptop.node, self.laptop_server.local_addr()),
            (&self.oracle.node, self.oracle_server.local_addr()),
            (&self.phone.node, self.phone_server.local_addr()),
        ]
    }

    /// What a rendezvous `/nodes` answer looks like for this fleet.
    fn discovery(&self) -> Value {
        json!({
            "nodes": self
                .addresses()
                .iter()
                .map(|(node, address)| json!({
                    "node_id": node.node_id,
                    "public_key": node.public_key,
                    "name": node.name,
                    "role": "master",
                    "endpoints": [address.to_string()],
                }))
                .collect::<Vec<_>>()
        })
    }

    /// A cache that already knows where everyone is, as after one rendezvous bootstrap.
    fn cache(&self) -> PeerCache {
        let mut cache = PeerCache::empty();
        cache.merge_roster(&self.roster, wire::now_millis());
        cache.merge_rendezvous(&self.discovery(), wire::now_millis());
        cache
    }
}

/// A rendezvous good enough to be killed: it answers `GET /nodes` and nothing else.
struct TestRendezvous {
    address: SocketAddr,
    stop: Arc<AtomicBool>,
    join: Option<std::thread::JoinHandle<()>>,
}

impl TestRendezvous {
    fn start(payload: Value) -> TestRendezvous {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("rendezvous bind");
        let address = listener.local_addr().expect("rendezvous address");
        listener.set_nonblocking(true).expect("non-blocking rendezvous listener");
        let stop = Arc::new(AtomicBool::new(false));
        let thread_stop = stop.clone();
        // Non-blocking accept and a polled stop flag, never a blocking `accept` woken by a throwaway
        // connect: a shutdown that depends on one more successful socket op can hang with no CPU
        // (see `testkit::ACCEPT_POLL`).
        let join = std::thread::spawn(move || {
            while !thread_stop.load(Ordering::SeqCst) {
                let mut stream = match listener.accept() {
                    Ok((stream, _)) => stream,
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(testkit::ACCEPT_POLL);
                        continue;
                    }
                    Err(_) => {
                        std::thread::sleep(testkit::ACCEPT_POLL);
                        continue;
                    }
                };
                let _ = stream.set_nonblocking(false);
                let _ = stream.set_read_timeout(Some(testkit::SOCKET_DEADLINE));
                let _ = stream.set_write_timeout(Some(testkit::SOCKET_DEADLINE));
                match http::read_request(&mut stream, http::MAX_BODY) {
                    Ok(Some(request)) if request.path.starts_with("/nodes") => {
                        let body = payload.to_string();
                        let _ = http::write_response(&mut stream, 200, &[], body.as_bytes());
                    }
                    _ => {
                        let _ = http::write_response(&mut stream, 404, &[], br#"{"error":"not_found"}"#);
                    }
                }
            }
        });
        TestRendezvous { address, stop, join: Some(join) }
    }

    fn nodes(&self) -> Value {
        let response = http::request(
            &self.address.to_string(),
            "GET",
            "/nodes",
            &[],
            b"",
            testkit::CONNECT_TIMEOUT,
            testkit::SOCKET_DEADLINE,
            http::MAX_BODY,
        )
        .expect("the rendezvous answers");
        assert_eq!(response.status, 200);
        serde_json::from_str(&response.body_text()).expect("nodes payload")
    }
}

impl Drop for TestRendezvous {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(join) = self.join.take() {
            // The thread polls `stop`; this join is bounded by one poll interval, never by a socket.
            let _ = join.join();
        }
    }
}

fn client<'a>(
    identity: &'a Identity,
    roster: &'a Roster,
    policy: &'a MeshPolicy,
    cache: &'a mut PeerCache,
    audit: &'a MemorySink,
) -> Client<'a> {
    client_with_connect(identity, roster, policy, cache, audit, testkit::CONNECT_TIMEOUT)
}

/// The same client with an explicit connect budget: the one test that wants a peer to be unreachable
/// asks for a short one so it can observe the failure without waiting out a generous timeout.
fn client_with_connect<'a>(
    identity: &'a Identity,
    roster: &'a Roster,
    policy: &'a MeshPolicy,
    cache: &'a mut PeerCache,
    audit: &'a MemorySink,
    connect_timeout: Duration,
) -> Client<'a> {
    Client {
        identity,
        roster,
        policy,
        cache,
        audit,
        config: ClientConfig {
            connect_timeout,
            io_timeout: testkit::SOCKET_DEADLINE,
            ..ClientConfig::default()
        },
    }
}

/// A signed mesh call, built by hand: these tests use it to be a caller the client would never be.
fn signed_call(
    caller: &Member,
    to: &RosterNode,
    capability: &str,
    ts: u64,
    request_id: &str,
) -> (String, Vec<(String, String)>) {
    let envelope = Envelope {
        schema: wire::SCHEMA,
        request_id: request_id.into(),
        from_node_id: caller.node.node_id.clone(),
        to_node_id: to.node_id.clone(),
        capability: capability.into(),
        args: json!({"path": "README.md"}),
        inner_body: "{}".into(),
        inner_headers: Vec::new(),
    };
    let body = envelope.encode();
    let signature = caller.identity.sign(&Envelope::call_message(&caller.node.node_id, ts, &body));
    let headers = vec![
        ("x-wa-mesh".to_string(), "1".to_string()),
        ("content-type".to_string(), "application/json".to_string()),
        ("x-wa-node".to_string(), caller.node.node_id.clone()),
        ("x-wa-pub".to_string(), caller.node.public_key.clone()),
        ("x-wa-ts".to_string(), ts.to_string()),
        ("x-wa-sig".to_string(), signature),
    ];
    (body, headers)
}

fn post(address: SocketAddr, body: &str, headers: &[(String, String)]) -> http::Response {
    http::request(
        &address.to_string(),
        "POST",
        "/mesh/call",
        headers,
        body.as_bytes(),
        testkit::CONNECT_TIMEOUT,
        testkit::SOCKET_DEADLINE,
        http::MAX_BODY,
    )
    .expect("the target answers")
}

fn get(address: SocketAddr, path: &str) -> http::Response {
    http::request(
        &address.to_string(),
        "GET",
        path,
        &[],
        b"",
        testkit::CONNECT_TIMEOUT,
        testkit::SOCKET_DEADLINE,
        http::MAX_BODY,
    )
    .expect("the node answers")
}

fn health(address: SocketAddr) -> Value {
    serde_json::from_str(&get(address, "/mesh/health").body_text()).expect("health body")
}

#[test]
fn three_nodes_call_each_other_after_the_rendezvous_dies() {
    testkit::with_deadline("three_nodes_call_each_other_after_the_rendezvous_dies", move || {
        let fleet = fleet();
        let rendezvous = TestRendezvous::start(fleet.discovery());

        // Bootstrap: the node asks the rendezvous where its peers are, exactly as `nodes.peers()` does.
        let payload = rendezvous.nodes();
        let directory = testkit::temp_dir("cache");
        let cache_path = directory.join("mesh").join("peers.json");
        let mut cache = PeerCache::empty();
        cache.merge_roster(&fleet.roster, wire::now_millis());
        cache.merge_rendezvous(&payload, wire::now_millis());
        cache.save(&cache_path, wire::now_millis()).expect("cache saved");

        // Kill the rendezvous. From here on nothing may depend on it.
        drop(rendezvous);

        // A fresh cache object read from disk: the call path has the peer list, not a live one.
        let mut cache = PeerCache::from_file(&cache_path).expect("cache reloaded");
        cache.merge_roster(&fleet.roster, wire::now_millis());
        let audit = MemorySink::new();
        let no_grants = &fleet.policy;

        // Level 0 -> level 1: allowed by the hierarchy, no grant involved.
        let mut laptop = client(&fleet.laptop.identity, &fleet.roster, no_grants, &mut cache, &audit);
        match laptop.call("oracle", "bash", json!({"command": "git log -1"}), Inner::default()) {
            Outcome::Ok { node, status, body, address, .. } => {
                assert_eq!(node.name, "oracle");
                assert_eq!(status, 200);
                assert!(address.starts_with("127.0.0.1:"), "the direct address was used: {address}");
                let answer: Value = serde_json::from_str(&body).expect("echo body");
                assert_eq!(answer["echo"], "bash");
                assert_eq!(answer["from"], "laptop");
                assert_eq!(answer["to"], "oracle");
            }
            other => panic!("laptop -> oracle must work with the rendezvous gone: {other:?}"),
        }

        // Level 1 -> level 1: the same level is allowed, whatever the verb.
        let mut oracle = client(&fleet.oracle.identity, &fleet.roster, no_grants, &mut cache, &audit);
        match oracle.call("phone", "read", json!({"path": "README.md"}), Inner::default()) {
            Outcome::Ok { node, .. } => assert_eq!(node.name, "phone"),
            other => panic!("a same-level call must be allowed: {other:?}"),
        }

        // Level 1 -> level 0: denied without a grant, and the answer says which rule refused it.
        let mut oracle = client(&fleet.oracle.identity, &fleet.roster, no_grants, &mut cache, &audit);
        match oracle.call("laptop", "bash", json!({"command": "rm -rf /"}), Inner::default()) {
            Outcome::Denied { node, verdict, verb } => {
                assert_eq!(node.name, "laptop");
                assert_eq!(verdict.reason, "hierarchy_denied");
                assert!(!verdict.is_allow());
                assert_eq!(verb, Verb::Control);
            }
            other => panic!("an upward call must be denied without a grant: {other:?}"),
        }

        // A grant is the operator's statement, written in the `mesh` section of a node's own policy.json.
        // The *target* holds the copy that executes: with the grant only on the caller's side, the laptop
        // still refuses: that is the second half of "both ends decide".
        let granted = MeshPolicy::from_policy_text(&format!(
            r#"{{"version":1,"mesh":{{"version":1,"roster_key":"{}","grants":[
                 {{"caller":"{}","target":"{}","verb":"control","effect":"allow",
                   "note":"the oracle may drive the laptop"}}]}}}}"#,
            fleet.fleet_key.public_key, fleet.oracle.node.node_id, fleet.laptop.node.node_id
        ))
        .expect("grant policy");
        let mut oracle = client(&fleet.oracle.identity, &fleet.roster, &granted, &mut cache, &audit);
        match oracle.call("laptop", "bash", json!({"command": "uptime"}), Inner::default()) {
            Outcome::Refused { code, verified, .. } => {
                assert_eq!(code, "mesh_denied");
                assert!(verified, "the target's denial is a signed answer");
            }
            other => panic!("the laptop has no grant in its own policy, so it must refuse: {other:?}"),
        }

        // The audit trail recorded the decisions, and recorded none of the arguments.
        let lines = audit.lines();
        assert!(lines.iter().any(|line| line.contains("decision=allow reason=hierarchy_allowed")));
        assert!(lines.iter().any(|line| line.contains("decision=deny reason=hierarchy_denied")));
        assert!(!lines.iter().any(|line| line.contains("grant_allowed")), "nothing was granted yet");
        assert!(
            !lines.iter().any(|line| line.contains("git log") || line.contains("rm -rf") || line.contains("uptime")),
            "audit lines must not carry the call's arguments: {lines:?}"
        );
    });
}

#[test]
fn the_target_refuses_an_upward_call_even_when_the_caller_authorizes_itself() {
    testkit::with_deadline("the_target_refuses_an_upward_call_even_when_the_caller_authorizes_itself", move || {
        // A caller that authorized itself — or a stolen key — still meets the target's roster. This is
        // the whole reason both ends run the same rule.
        let fleet = fleet();
        let (body, headers) = signed_call(&fleet.oracle, &fleet.laptop.node, "bash", wire::now_seconds(), "self-authorized");
        let response = post(fleet.laptop_server.local_addr(), &body, &headers);
        assert_eq!(
            response.status, 200,
            "an authenticated refusal is a signed answer, not a transport error"
        );
        let reply_signature = response.header("x-wa-sig").expect("signed reply").to_string();
        let reply_ts: u64 = response.header("x-wa-ts").expect("reply ts").parse().expect("reply ts");
        let reply_text = response.body_text();
        assert!(
            crate::identity::verify(
                &fleet.laptop.node.public_key,
                &MeshReply::reply_message(&fleet.laptop.node.node_id, &fleet.oracle.node.node_id, reply_ts, &reply_text),
                &reply_signature,
            ),
            "the denial must be signed by the target"
        );
        let reply = MeshReply::parse(&reply_text).expect("reply body");
        assert!(!reply.ok);
        assert_eq!(reply.error.as_deref(), Some("mesh_denied"));
        assert_eq!(reply.reason.as_deref(), Some("hierarchy_denied"));
    });
}

#[test]
fn a_replayed_call_a_stale_call_and_a_redirected_call_are_all_refused() {
    testkit::with_deadline("a_replayed_call_a_stale_call_and_a_redirected_call_are_all_refused", move || {
        let fleet = fleet();
        let target = fleet.oracle_server.local_addr();

        // A good call, then the very same bytes again: the second one is a replay.
        let (body, headers) = signed_call(&fleet.laptop, &fleet.oracle.node, "read", wire::now_seconds(), "once");
        let first = post(target, &body, &headers);
        assert_eq!(first.status, 200);
        let second = post(target, &body, &headers);
        assert_eq!(second.status, 409);
        assert_eq!(wire::pre_auth_code(&second.body_text()), Some("replayed_request"));

        // A body altered after signing: `read` becomes `bash`.
        let (body, headers) = signed_call(&fleet.laptop, &fleet.oracle.node, "read", wire::now_seconds(), "altered");
        let altered = body.replace("\"capability\":\"read\"", "\"capability\":\"bash\"");
        assert_ne!(altered, body);
        let refused = post(target, &altered, &headers);
        assert_eq!(refused.status, 401);
        assert_eq!(wire::pre_auth_code(&refused.body_text()), Some("bad_signature"));

        // A call signed for one node and delivered to another.
        let (body, headers) = signed_call(&fleet.laptop, &fleet.phone.node, "read", wire::now_seconds(), "redirected");
        let refused = post(target, &body, &headers);
        assert_eq!(refused.status, 403);
        assert_eq!(wire::pre_auth_code(&refused.body_text()), Some("wrong_target"));

        // A call from an hour ago.
        let (body, headers) = signed_call(&fleet.laptop, &fleet.oracle.node, "read", wire::now_seconds() - 3_600, "stale");
        let refused = post(target, &body, &headers);
        assert_eq!(refused.status, 408);
        assert_eq!(wire::pre_auth_code(&refused.body_text()), Some("stale_request"));

        // A caller the roster does not know at all.
        let outsider = Member::new("outsider", 1, &[]);
        let (body, headers) = signed_call(&outsider, &fleet.oracle.node, "read", wire::now_seconds(), "outsider");
        let refused = post(target, &body, &headers);
        assert_eq!(refused.status, 403);
        assert_eq!(wire::pre_auth_code(&refused.body_text()), Some("unknown_caller"));
    });
}

#[test]
fn a_tampered_roster_is_refused_and_a_node_holding_one_serves_nothing() {
    testkit::with_deadline("a_tampered_roster_is_refused_and_a_node_holding_one_serves_nothing", move || {
        let fleet = fleet();
        let tampered = testkit::tampered(fleet.roster.clone(), &fleet.fleet_key);
        let error = tampered
            .verify(&fleet.fleet_key.public_key, wire::now_seconds())
            .expect_err("a roster edited after signing must not verify");
        assert_eq!(error.0, "roster_unverified:bad_signature");

        // A node that loads that roster refuses every call instead of trusting it.
        let stranger = Member::new("tampered-node", 1, &[]);
        let policy = MeshPolicy::from_policy_text(&format!(
            r#"{{"version":1,"mesh":{{"version":1,"roster_key":"{}"}}}}"#,
            fleet.fleet_key.public_key
        ))
        .unwrap();
        let server = start(&stranger, &tampered, &policy);
        let status = health(server.local_addr());
        assert_eq!(status["roster_verified"], false);
        assert!(status["roster_status"].as_str().unwrap().starts_with("roster_unverified"));

        let (body, headers) = signed_call(&fleet.laptop, &fleet.oracle.node, "read", wire::now_seconds(), "into-tampered");
        let refused = post(server.local_addr(), &body, &headers);
        assert_eq!(refused.status, 503);
        assert_eq!(wire::pre_auth_code(&refused.body_text()), Some("roster_unverified"));
    });
}

#[test]
fn a_denial_never_offers_a_fallback_and_an_unreachable_peer_does() {
    testkit::with_deadline("a_denial_never_offers_a_fallback_and_an_unreachable_peer_does", move || {
        let fleet = fleet();
        let mut cache = fleet.cache();
        let audit = MemorySink::new();
        let no_grants = &fleet.policy;

        // Denied: an answer, and it must not invite the relay to take over.
        let mut oracle = client(&fleet.oracle.identity, &fleet.roster, no_grants, &mut cache, &audit);
        let denied = oracle
            .call("laptop", "write", json!({"path": "x", "content": "y"}), Inner::default())
            .to_json();
        assert_eq!(denied["error"], "mesh_denied");
        assert!(denied["fallback"].is_null(), "a denial must not carry a fallback: {denied}");

        // Unreachable: nobody decided, so the caller's existing path may run.
        let mut cache = PeerCache::empty();
        cache.merge_roster(&fleet.roster, wire::now_millis());
        cache.merge_rendezvous(
            &json!({"nodes": [{"node_id": fleet.phone.node.node_id, "name": "phone",
                                "public_key": fleet.phone.node.public_key,
                                "endpoints": ["127.0.0.1:1"]}]}),
            wire::now_millis(),
        );
        // A short connect budget: this peer is meant to stay unreachable, so the test should observe
        // the failure quickly instead of waiting out the generous budget the live calls use.
        let mut laptop = client_with_connect(
            &fleet.laptop.identity,
            &fleet.roster,
            no_grants,
            &mut cache,
            &audit,
            Duration::from_secs(2),
        );
        let unreachable = laptop.call("phone", "read", json!({}), Inner::default()).to_json();
        assert_eq!(unreachable["error"], "mesh_unreachable");
        assert_eq!(unreachable["fallback"], "relay");
        assert!(!unreachable["attempts"].as_array().unwrap().is_empty());
    });
}

#[test]
fn the_health_endpoint_names_the_node_without_authenticating_anything() {
    testkit::with_deadline("the_health_endpoint_names_the_node_without_authenticating_anything", move || {
        let fleet = fleet();
        let status = health(fleet.oracle_server.local_addr());
        assert_eq!(status["node_id"], fleet.oracle.node.node_id);
        assert_eq!(status["name"], "oracle");
        assert_eq!(status["level"], 1);
        assert_eq!(status["roster_verified"], true);
        assert!(status["unsigned"].as_str().unwrap().contains("does not authenticate"));
        // An unknown route is a code, not an HTML page.
        let missing = get(fleet.oracle_server.local_addr(), "/nope");
        assert_eq!(missing.status, 404);
        assert_eq!(wire::pre_auth_code(&missing.body_text()), Some("not_found"));
    });
}

#[test]
fn the_callers_own_request_reaches_the_target_untouched() {
    testkit::with_deadline("the_callers_own_request_reaches_the_target_untouched", move || {
        // `Inner` is the caller's own `/node/call` body and headers: the node forwards *that* to execute
        // the capability, so it must arrive byte for byte and inside the mesh signature.
        let fleet = fleet();
        let mut cache = fleet.cache();
        let audit = MemorySink::new();
        let no_grants = &fleet.policy;
        let inner = Inner {
            body: "{\"to_node_id\":\"x\",\"capability\":\"read\",\"args\":{\"path\":\"README.md\"}}".into(),
            headers: vec![
                ("X-WA-Node".into(), fleet.laptop.node.node_id.clone()),
                ("X-WA-Sig".into(), "abcdef".into()),
            ],
        };
        let mut caller = client(&fleet.laptop.identity, &fleet.roster, no_grants, &mut cache, &audit);
        match caller.call("phone", "read", json!({"path": "README.md"}), inner.clone()) {
            Outcome::Ok { body, .. } => {
                let answer: Value = serde_json::from_str(&body).expect("echo body");
                assert_eq!(answer["inner_body"], inner.body);
                assert_eq!(answer["inner_headers"][0], format!("X-WA-Node: {}", fleet.laptop.node.node_id));
                assert_eq!(answer["inner_headers"][1], "X-WA-Sig: abcdef");
                assert_eq!(answer["verb"], "read");
            }
            other => panic!("the call must reach the target: {other:?}"),
        }
    });
}

#[test]
fn an_upward_call_works_when_both_ends_carry_the_operator_grant() {
    testkit::with_deadline("an_upward_call_works_when_both_ends_carry_the_operator_grant", move || {
        // The same fleet, with the grant in `policy.json` on both ends, which is what an operator writes:
        // the caller's copy stops a call it knows is not allowed, the target's copy is the one that
        // executes, and a fleet whose two copies disagree refuses (see the test above).
        let fleet = fleet_with_grants(true);
        let mut cache = fleet.cache();
        let audit = MemorySink::new();
        let policy = &fleet.policy;

        let mut oracle = client(&fleet.oracle.identity, &fleet.roster, policy, &mut cache, &audit);
        match oracle.call("laptop", "bash", json!({"command": "uptime"}), Inner::default()) {
            Outcome::Ok { verdict, node, .. } => {
                assert_eq!(node.name, "laptop");
                assert_eq!(verdict.reason, "grant_allowed");
            }
            other => panic!("a granted upward call must work: {other:?}"),
        }

        // The same grant does not cover a verb it does not name, in either direction.
        let mut oracle = client(&fleet.oracle.identity, &fleet.roster, policy, &mut cache, &audit);
        let read_denied = oracle
            .call("laptop", "read", json!({"path": "README.md"}), Inner::default())
            .to_json();
        assert_eq!(read_denied["error"], "mesh_denied");
        assert_eq!(read_denied["reason"], "hierarchy_denied");

        // And the level-0 laptop still needs no grant at all.
        let mut laptop = client(&fleet.laptop.identity, &fleet.roster, policy, &mut cache, &audit);
        assert!(matches!(
            laptop.call("oracle", "bash", json!({"command": "uptime"}), Inner::default()),
            Outcome::Ok { .. }
        ));
    });
}

#[test]
fn the_mount_starts_only_when_the_flag_and_a_port_are_both_given() {
    testkit::with_deadline("the_mount_starts_only_when_the_flag_and_a_port_are_both_given", move || {
        // The one thing `serve.rs` calls: the live mount, which reads the flag and the port every poll.
        // This is the only place the real file paths (home, policy.json, roster, cache, audit) are
        // exercised, so the wiring the node does is tested without starting a node.
        let _lock = testkit::ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let home = testkit::temp_dir("mount-home");
        let config = home.join(".wasm-agent");
        std::fs::create_dir_all(&config).expect("config dir");

        // The node's own key, in the place the mount looks for it: <home>/.wasm-agent/node.key.
        let node_identity = Identity::load(&config.join("node.key")).expect("node identity");
        let fleet_key = testkit::fleet_key();
        let node = RosterNode {
            node_id: node_identity.node_id.clone(),
            public_key: node_identity.public_key.clone(),
            name: "mounted".into(),
            level: 0,
            addresses: Vec::new(),
            revoked_at: 0,
        };
        let roster = testkit::roster_of(&fleet_key, vec![node.clone()]);
        std::fs::write(config.join("mesh-roster.json"), serde_json::to_string_pretty(&roster).unwrap())
            .expect("roster file");
        std::fs::write(
            config.join("policy.json"),
            format!(
                r#"{{"version":1,"components":{{}},"mesh":{{"version":1,"roster_key":"{}"}}}}"#,
                fleet_key.public_key
            ),
        )
        .expect("policy file");

        let port = testkit::free_port();
        let _env = testkit::EnvGuard::set(&[
            ("WASM_AGENT_HOME", Some(home.to_str().unwrap())),
            ("WASM_AGENT_NODE_KEY", None),
            ("WA_MESH", Some("1")),
            ("WASM_AGENT_MESH", None),
            ("WASM_AGENT_MESH_PORT", Some(&port.to_string())),
            ("WASM_AGENT_MESH_BIND", None),
            ("WASM_AGENT_MESH_ROSTER", None),
            ("WASM_AGENT_MESH_CACHE", None),
            ("WA_GRANT_POLICY", None),
            ("WASM_AGENT_MESH_POLL_MS", Some("20")),
        ]);
        let mount = crate::host_call::spawn_supervisor(port);
        let listening = wait_for_mount(&mount, |status| status.listening);
        assert_eq!(listening.port, Some(port));
        assert!(listening.roster_verified, "{listening:?}");
        let status = health((std::net::Ipv4Addr::LOCALHOST, port).into());
        assert_eq!(status["node_id"], node.node_id);
        assert_eq!(status["name"], "mounted");
        assert_eq!(status["roster_verified"], true);
        drop(mount);

        // The flag without a port opens nothing, and says so on stderr rather than picking one.
        let _no_port = testkit::EnvGuard::set(&[("WASM_AGENT_MESH_PORT", None)]);
        let mount = crate::host_call::spawn_supervisor(port);
        let status = wait_for_mount(&mount, |status| !status.listening);
        assert!(status.changes == 0, "a flag with no port mounts nothing: {status:?}");
        drop(mount);

        // No flag at all: the mount is silent and touches no file.
        let _off = testkit::EnvGuard::set(&[
            ("WA_MESH", None),
            ("WASM_AGENT_MESH", None),
            ("WASM_AGENT_MESH_PORT", Some(&port.to_string())),
        ]);
        let mount = crate::host_call::spawn_supervisor(port);
        let status = wait_for_mount(&mount, |status| !status.listening);
        assert!(!status.enabled, "the port alone never turns the mesh on: {status:?}");
        assert_eq!(status.changes, 0, "{status:?}");
        let _ = std::fs::remove_dir_all(&home);
    });
}

/// Wait for the mount to reach a state, or fail naming what it was still doing.
fn wait_for_mount(
    mount: &crate::host_call::Supervisor,
    done: impl Fn(&crate::host_call::MountStatus) -> bool,
) -> crate::host_call::MountStatus {
    let deadline = std::time::Instant::now() + Duration::from_secs(30);
    loop {
        let status = mount.status();
        if done(&status) {
            return status;
        }
        assert!(std::time::Instant::now() < deadline, "the mount never settled: {status:?}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn a_hung_body_fails_by_name_instead_of_blocking_the_binary() {
    // The guard that keeps this suite from hanging, tested on itself: a body that never returns is
    // reported as a failure naming the test, not waited on forever. The thread it leaves behind is
    // asleep, so libtest's exit does not wait for it.
    let hung = std::panic::catch_unwind(|| {
        testkit::with_deadline_for("pretend-hang", Duration::from_millis(150), || {
            std::thread::sleep(Duration::from_secs(5));
        })
    })
    .expect_err("an overrunning body must fail the test");
    let message = hung
        .downcast_ref::<String>()
        .cloned()
        .or_else(|| hung.downcast_ref::<&str>().map(|text| (*text).to_string()))
        .unwrap_or_default();
    assert!(message.contains("pretend-hang"), "{message}");
    assert!(message.contains("did not finish"), "{message}");

    // A body that panics keeps its own message and does not look like a timeout.
    let failed = std::panic::catch_unwind(|| {
        testkit::with_deadline_for("pretend-panic", Duration::from_secs(5), || {
            panic!("the body's own assertion");
        })
    })
    .expect_err("a panicking body must fail the test");
    let message = failed
        .downcast_ref::<&str>()
        .map(|text| (*text).to_string())
        .or_else(|| failed.downcast_ref::<String>().cloned())
        .unwrap_or_default();
    assert_eq!(message, "the body's own assertion");
}
