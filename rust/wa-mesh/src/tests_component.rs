//! The `wa:mesh` seam against the native rule, answer for answer: the parity evidence for
//! `docs/CORE-SPLIT.md`'s fourth extraction.
//!
//! The whole suite can be run with `WA_MESH_COMPONENT=1` (`scripts/test-mesh-component.sh`) and it passes
//! on both paths — but "both paths pass" is not the same claim as "both paths answer the same thing", and
//! it is certainly not "the component answered". So this file asks the component **directly**
//! (`wa_kernel_runtime::mesh_host::call`, no environment, no fallback of any kind) and compares every
//! answer with the native function it is supposed to replace:
//!
//! * `verify-roster` — the levels, the fingerprint and the exact refusal sentence (a tampered roster is
//!   `roster_unverified:bad_signature` on both, and the seam is *not* allowed to name it differently);
//! * `decide` — `allow`, `reason` and `detail` for the hierarchy, a grant, a deny grant, a revocation and
//!   a self-call;
//! * `render-audit` — the line, character for character;
//! * `addresses` — the dial order;
//! * `attest-message` / `verify-ticket` — the signed bytes and every failure slug.
//!
//! The artifact is found by [`component`] and the file is **SKIPPED, with a printed line** when this
//! checkout has not built it: a skip is never counted as a pass.
use serde_json::{json, Value};

use crate::identity::{generate, verify};
use crate::policy::MeshPolicy;
use crate::roster::{Draft, Roster, RosterNode};
use crate::testkit;
use wa_kernel_runtime::mesh_host::{self, Config};

/// The built component, wherever this checkout put it: `WA_MESH_COMPONENT_WASM` wins, then the in-tree
/// build, then the workspace target dir.
fn component() -> Option<(std::path::PathBuf, std::path::PathBuf)> {
    let manifest = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../components/mesh/manifest.json");
    let mut candidates: Vec<std::path::PathBuf> = Vec::new();
    if let Ok(path) = std::env::var("WA_MESH_COMPONENT_WASM") {
        candidates.push(std::path::PathBuf::from(path));
    }
    let manifest_dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    candidates.push(manifest_dir.join("../components/mesh/target/wasm32-wasip2/release/mesh.wasm"));
    if let Ok(target) = std::env::var("CARGO_TARGET_DIR") {
        candidates.push(std::path::PathBuf::from(target).join("wasm32-wasip2/release/mesh.wasm"));
    }
    candidates.into_iter().find(|path| path.is_file()).map(|path| (path, manifest))
}

fn config() -> Option<Config> {
    let (wasm, manifest) = component()?;
    Some(Config::from_env().with_artifact(wasm, manifest))
}

fn ask(config: &Config, request: Value) -> Value {
    let answer = mesh_host::call_with(config, &request);
    assert_eq!(answer["ok"], json!(true), "the component answered: {answer}");
    answer
}

/// One fleet: levels 0/1/1/2, one revocation, one grant-only upward call.
struct Fleet {
    roster: Roster,
    policy: MeshPolicy,
    /// The key that signed `roster`. A fresh `testkit::fleet_key()` is a *different* key every call, so
    /// a test that took a second one would be verifying the roster against a stranger's signature, and
    /// the refusal (correctly: `roster_unverified:bad_signature`) would look like a parity failure.
    key: crate::identity::Identity,
}

fn fleet() -> Fleet {
    let key = testkit::fleet_key();
    let draft = Draft {
        fleet: "ohana".into(),
        issued_at: 1_762_000_000,
        expires_at: 1_793_536_000,
        nodes: vec![
            testkit::node("laptop", 0, &["147.15.64.233:8891", "192.168.1.10:8891"]),
            testkit::node("oracle", 1, &["10.0.0.5:8891"]),
            testkit::node("phone", 1, &[]),
            testkit::node("guest", 2, &[]),
        ],
    };
    let roster = draft.sign(&key);
    // A grant for the one upward call this fleet allows, in the operator's own policy language.
    let policy = MeshPolicy::from_policy_text(&format!(
        r#"{{"version":1,"mesh":{{"version":1,"grants":[
             {{"caller":"*","target":"{}","verb":"read","effect":"allow","note":"read the logs"}},
             {{"caller":"{}","target":"{}","verb":"control","effect":"deny"}}]}}}}"#,
        roster.nodes[0].node_id, roster.nodes[3].node_id, roster.nodes[2].node_id
    ))
    .expect("policy");
    Fleet { roster, policy, key }
}

fn node_json(node: &RosterNode) -> Value {
    json!({
        "id": node.node_id,
        "public_key": node.public_key,
        "name": node.name,
        "level": node.level,
        "addresses": node.addresses,
        "revoked_at": node.revoked_at,
    })
}

fn grants_json(policy: &MeshPolicy) -> Vec<Value> {
    policy
        .grants
        .iter()
        .map(|grant| {
            json!({
                "caller": grant.caller.as_str(),
                "target": grant.target.as_str(),
                "verb": grant.verb.as_str(),
                "effect": match grant.effect { crate::policy::Effect::Allow => "allow", crate::policy::Effect::Deny => "deny" },
                "note": grant.note,
            })
        })
        .collect()
}

#[test]
fn the_component_and_the_native_rule_answer_the_same_verdicts() {
    let Some(config) = config() else {
        println!("mesh component: SKIPPED the parity verdicts (no built mesh.wasm: run scripts/build-components.sh mesh)");
        return;
    };
    let fleet = fleet();
    let now = 1_762_000_100u64;
    let policy = &fleet.policy;
    let nodes = &fleet.roster.nodes;
    // Every ordered pair, every verb: the hierarchy, both grants and the default deny, exhaustively.
    let mut cases = 0;
    for caller in nodes {
        for target in nodes {
            for verb in [crate::hierarchy::Verb::Read, crate::hierarchy::Verb::Call, crate::hierarchy::Verb::Control] {
                let native = crate::hierarchy::authorize(policy, caller, target, verb, now);
                let answer = ask(
                    &config,
                    json!({
                        "op": "decide",
                        "grants": grants_json(policy),
                        "caller": node_json(caller),
                        "target": node_json(target),
                        "verb": verb.as_str(),
                        "now": now,
                    }),
                );
                assert_eq!(answer["result"]["allow"], json!(native.allow), "{} -> {} {:?}", caller.name, target.name, verb);
                assert_eq!(answer["result"]["reason"], json!(native.reason), "{} -> {} {:?}", caller.name, target.name, verb);
                assert_eq!(answer["result"]["detail"], json!(native.detail), "{} -> {} {:?}", caller.name, target.name, verb);
                cases += 1;
            }
        }
    }
    assert!(cases >= 48, "the fleet has four nodes and three verbs: {cases}");

    // A revoked node, on both sides of a call: the refusal word, from the same rule.
    let mut revoked = nodes.clone();
    revoked[3].revoked_at = now - 10;
    for (caller, target) in [(3usize, 0usize), (0, 3)] {
        let native = crate::hierarchy::authorize(policy, &revoked[caller], &revoked[target], crate::hierarchy::Verb::Read, now);
        let answer = ask(
            &config,
            json!({
                "op": "decide",
                "grants": grants_json(policy),
                "caller": node_json(&revoked[caller]),
                "target": node_json(&revoked[target]),
                "verb": "read",
                "now": now,
            }),
        );
        assert_eq!(answer["result"]["reason"], json!(native.reason));
        assert_eq!(native.reason, "revoked");
    }
}

#[test]
fn the_component_verifies_a_roster_and_refuses_a_tampered_one_with_the_same_sentence() {
    let Some(config) = config() else {
        println!("mesh component: SKIPPED the roster parity (no built mesh.wasm)");
        return;
    };
    let fleet = fleet();
    let key = &fleet.key;
    let document = serde_json::to_string(&fleet.roster).expect("encode");
    let answer = ask(&config, json!({"op": "verify_roster", "document": document, "key": key.public_key, "now": 1_762_000_100}));
    let levels = answer["result"]["levels"].as_array().cloned().unwrap_or_else(|| panic!("levels: {answer}"));
    assert_eq!(levels.len(), fleet.roster.nodes.len());
    for (index, node) in fleet.roster.nodes.iter().enumerate() {
        assert_eq!(levels[index]["id"], json!(node.node_id));
        assert_eq!(levels[index]["level"], json!(node.level));
        assert_eq!(levels[index]["public_key"], json!(node.public_key));
    }
    assert_eq!(answer["result"]["fingerprint"], json!(fleet.roster.fingerprint()));

    // A roster edited after signing: the native sentence and the component's are one sentence.
    let tampered = testkit::tampered(fleet.roster.clone(), key);
    let native = crate::seam::verify_roster(&tampered, &key.public_key, 1_762_000_100)
        .expect_err("a tampered roster must not verify");
    let document = serde_json::to_string(&tampered).expect("encode");
    let refused = mesh_host::call_with(&config, &json!({"op": "verify_roster", "document": document, "key": key.public_key, "now": 1_762_000_100}));
    assert_eq!(refused["refused"]["error"], json!(native.0), "the same sentence, not a second vocabulary");

    // ... and the same for every other refusal the roster can make. The native side is the *same*
    // document through `Roster::parse` + `verify`; a parse error is a refusal too, and the two sentences
    // are asserted to be one string rather than "both failed somehow".
    let too_deep = Draft {
        fleet: "ohana".into(),
        issued_at: 1_762_000_000,
        expires_at: 0,
        nodes: vec![testkit::node("deep", 12, &[])],
    }
    .sign(key);
    let mut revoked_roster = fleet.roster.clone();
    revoked_roster.nodes[0].level = 9;
    revoked_roster.sign(key);
    for (document, key_text, at) in [
        ("{}".to_string(), key.public_key.clone(), 1_762_000_100u64),
        ("not json".to_string(), key.public_key.clone(), 1_762_000_100),
        (serde_json::to_string(&fleet.roster).unwrap(), String::new(), 1_762_000_100),
        (serde_json::to_string(&fleet.roster).unwrap(), "short".to_string(), 1_762_000_100),
        // The window: expired, and issued in the future.
        (serde_json::to_string(&fleet.roster).unwrap(), key.public_key.clone(), 1_793_536_000),
        (serde_json::to_string(&fleet.roster).unwrap(), key.public_key.clone(), 1_700_000_000),
        // A signed roster whose shape is refused *after* the signature was believed.
        (serde_json::to_string(&too_deep).unwrap(), key.public_key.clone(), 1_762_000_100),
        (serde_json::to_string(&revoked_roster).unwrap(), key.public_key.clone(), 1_762_000_100),
    ] {
        let answer = mesh_host::call_with(
            &config,
            &json!({"op": "verify_roster", "document": document, "key": key_text, "now": at}),
        );
        assert_eq!(answer["ok"], json!(true), "{answer}");
        let native = match Roster::parse(&document) {
            Err(error) => Err(error),
            Ok(parsed) => parsed.verify(crate::identity::crypto(), &key_text, at),
        };
        match native {
            Err(error) => assert_eq!(answer["refused"]["error"], json!(error.0), "{}", error.0),
            Ok(()) => assert!(answer["result"].is_object(), "{answer}"),
        }
    }
}

#[test]
fn the_component_renders_the_same_audit_line_and_orders_addresses_the_same_way() {
    let Some(config) = config() else {
        println!("mesh component: SKIPPED the audit/address parity (no built mesh.wasm)");
        return;
    };
    let fleet = fleet();
    // Every combination of the fields an operator reads, in both decisions and all three kinds.
    for kind in ["call", "recv", "reply"] {
        for decision in ["allow", "deny"] {
            for status in [None, Some(200u16), Some(403)] {
                for levels in [None, Some((0u8, 2u8))] {
                    let event = crate::audit::Event::new(kind, "8c11f0a2deadbeef", "3f2a91cdcafebabe")
                        .verb("control")
                        .verdict(decision, "hierarchy_allowed")
                        .transport("direct:lan", "private")
                        .outcome(decision == "allow", status, 41, 1);
                    let event = match levels {
                        Some((from, to)) => event.levels(Some(from), Some(to)),
                        None => event,
                    };
                    let answer = ask(
                        &config,
                        json!({"op": "render_audit", "event": {
                            "kind": event.kind,
                            "from": event.from,
                            "to": event.to,
                            "from_level": event.from_level,
                            "to_level": event.to_level,
                            "verb": event.verb,
                            "decision": event.decision,
                            "reason": event.reason,
                            "transport": event.transport,
                            "addr_class": event.class,
                            "ok": event.ok,
                            "status": event.status,
                            "ms": event.ms,
                            "attempt": event.attempt,
                        }}),
                    );
                    assert_eq!(answer["result"], json!(event.render()), "{kind}/{decision}/{status:?}/{levels:?}");
                }
            }
        }
    }

    // The dial order: the roster's own list first, cheapest class first, then what the cache learned.
    let mut cache = crate::cache::PeerCache::empty();
    cache.merge_roster(&fleet.roster, 1_762_000_000);
    cache.record_success(&fleet.roster.nodes[1].node_id, "127.0.0.1:8891", 1_762_000_100);
    cache.record_success(&fleet.roster.nodes[1].node_id, "8.8.8.8:8891", 1_762_000_100);
    for node in &fleet.roster.nodes {
        let learned: Vec<String> = cache.peer(&node.node_id).map(|entry| entry.addresses.clone()).unwrap_or_default();
        let answer = ask(&config, json!({"op": "addresses", "target": node_json(node), "learned": learned}));
        let want: Vec<Value> = cache.addresses(node).into_iter().map(Value::String).collect();
        assert_eq!(answer["result"].as_array().cloned().unwrap_or_default(), want, "{}", node.name);
    }

    // The verb a capability needs, for the three classes and an unknown one.
    for (capability, want) in [
        ("read", "read"),
        ("grep", "read"),
        ("bash", "control"),
        ("write_file", "control"),
        ("something_new", "call"),
    ] {
        let answer = ask(&config, json!({"op": "verb", "capability": capability}));
        assert_eq!(answer["result"], json!(want), "{capability}");
    }
}

#[test]
fn the_component_composes_the_same_attestation_and_refuses_the_same_tickets() {
    let Some(config) = config() else {
        println!("mesh component: SKIPPED the attestation parity (no built mesh.wasm)");
        return;
    };
    let (_text, identity) = generate().expect("identity");
    let ts = 1_762_000_000u64;
    let message = wa_mesh_core::attest::message(&identity.node_id, "8c11", "read", "sessions", "ab12", ts);
    let answer = ask(
        &config,
        json!({
            "op": "attest_message",
            "node_id": identity.node_id,
            "caller": "8c11",
            "verb": "read",
            "capability": "sessions",
            "caller_signature": "ab12",
            "ts": ts,
        }),
    );
    assert_eq!(answer["result"], json!(message), "the guest computes the bytes the node signs");
    // The node signs those bytes with ring, and they verify — the two ed25519 implementations agree.
    let signature = identity.sign(&message);
    assert!(verify(&identity.public_key, &message, &signature));

    // ... and the component checks what the node signed, refusing every wrong binding by name.
    let ticket = |signature: &str| json!({"caller": "8c11", "verb": "read", "capability": "sessions", "ts": ts, "signature": signature});
    let answer = ask(
        &config,
        json!({
            "op": "verify_ticket",
            "ticket": ticket(&signature),
            "node_id": identity.node_id,
            "node_public_key": identity.public_key,
            "caller_signature": "ab12",
            "now": ts + 5,
        }),
    );
    assert_eq!(answer["result"]["caller"], json!("8c11"));
    assert_eq!(answer["result"]["verb"], json!("read"));
    for (body, want) in [
        (json!({"op": "verify_ticket", "ticket": ticket(""), "node_id": identity.node_id, "node_public_key": identity.public_key, "caller_signature": "ab12", "now": ts}), "attestation_absent"),
        (json!({"op": "verify_ticket", "ticket": ticket(&signature), "node_id": identity.node_id, "node_public_key": identity.public_key, "caller_signature": "ef34", "now": ts}), "attestation_bad_signature"),
        (json!({"op": "verify_ticket", "ticket": ticket(&signature), "node_id": identity.node_id, "node_public_key": identity.public_key, "caller_signature": "ab12", "now": ts + 100_000}), "attestation_stale"),
    ] {
        let answer = mesh_host::call_with(&config, &body);
        assert_eq!(answer["refused"]["error"], json!(want), "{answer}");
        // The native rule names the same failure the same way.
        let native = crate::seam::verify_attestation(
            &identity.public_key,
            &identity.node_id,
            "8c11",
            "read",
            "sessions",
            body["caller_signature"].as_str().unwrap_or_default(),
            ts,
            body["ticket"]["signature"].as_str().unwrap_or_default(),
            body["now"].as_u64().unwrap_or_default(),
        );
        assert_eq!(native.map(|bound| bound.caller).map_err(|error| error.slug()), Err(want), "{body}");
    }
}
