//! The node half, without a node: one [`FabricNode`] over a `MemoryKv` and a `FixedClock`, and the
//! process-wide surface driven from this test's own thread (the fabric is per node-thread).

use std::sync::Arc;

use serde_json::json;
use wa_fabric::offer::{Accept, Offer, Reply};
use wa_fabric::placement::LocalReason;
use wa_fabric::presence::{Capabilities, Heartbeat, Load, NodeId};
use wa_fabric::Config;
use wa_queue::{FixedClock, MemoryKv};

use super::*;

fn node(id: &str, now: i64) -> (FabricNode, Arc<FixedClock>) {
    let clock = Arc::new(FixedClock::new(now));
    let mut node = FabricNode::new(id, Config::default(), Arc::new(MemoryKv::new()), clock.clone()).expect("node");
    node.set_caps(["stt"]);
    node.set_load(5, 20);
    (node, clock)
}

/// Put `peer`'s heartbeat into `node`'s view, as the pump would.
fn see(node: &mut FabricNode, peer: &FabricNode, now: i64) {
    node.observe(peer.heartbeat(now), now);
}

#[test]
fn publishing_queues_one_call_per_live_peer_and_keeps_self_in_the_view() {
    let now = 1_000;
    let (mut small, _) = node("small", now);
    let (big, _) = node("big", now);
    see(&mut small, &big, now);

    assert_eq!(small.publish(now), 1, "one call for the one live peer");
    assert_eq!(small.queued(), 1);
    assert!(small.view().is_live("small", now), "self is a candidate only if it publishes to itself");
    assert!(small.view().is_live("big", now));
    let call = small.next_call().expect("a call");
    assert_eq!(call.op, "beat");
    assert_eq!(call.to, "big");
    let beat = Heartbeat::decode(call.body.as_bytes()).expect("a heartbeat");
    assert_eq!(beat.node.as_str(), "small");
}

#[test]
fn a_submission_offers_the_idle_peer_and_the_accept_places_it() {
    let now = 1_000;
    let (mut small, _) = node("small", now);
    let (mut big, _) = node("big", now);
    small.set_load(80, 40); // this node is busy; the peer is idle
    see(&mut small, &big, now);
    small.publish(now);
    let _ = small.next_call();

    let submission = small.submit("stt", b"audio".to_vec(), now).expect("submitted");
    assert!(matches!(submission.plan, wa_fabric::Plan::Offer { .. }));
    assert!(!submission.local);
    let call = small.next_call().expect("the offer");
    assert_eq!(call.op, "offer");
    assert_eq!(call.to, "big");

    // The peer answers from its own load, then the pump delivers the answer.
    let offer = Offer::decode(call.body.as_bytes()).expect("an offer");
    let answer = big.answer(&offer, now);
    assert_eq!(answer["accept"], json!(offer.rid));
    let accept = Accept::decode(answer.to_string().as_bytes()).expect("an accept");
    let resolution = small.on_reply(submission.job.0, Reply::Accept(accept), now);
    assert_eq!(resolution, Resolution::Placed { node: "big".into(), rtt_ms: 0 });
    assert_eq!(small.metrics().placed, 1);
    assert_eq!(small.router.in_flight(), 0);
}

#[test]
fn a_tie_runs_here_and_takes_the_lease() {
    let now = 1_000;
    let (mut small, _) = node("small", now);
    let (big, _) = node("big", now);
    see(&mut small, &big, now);
    small.publish(now);
    let _ = small.next_call(); // the heartbeat the publish queued

    let submission = small.submit("stt", b"audio".to_vec(), now).expect("submitted");
    assert!(submission.local, "a tie runs locally");
    assert_eq!(submission.plan, wa_fabric::Plan::Local { because: LocalReason::SelfBest });
    assert_eq!(small.queued(), 0, "nothing was offered");

    let lease = small.take("stt", 5_000, now).expect("took").expect("a job");
    assert_eq!(lease.job, submission.job);
    assert_eq!(lease.worker, "small:1");
    assert!(small.lease(submission.job.0).is_some());
    small.settle(&lease, b"transcript").expect("settled");
    assert_eq!(small.metrics().settled, 1);
    // The queue's fence: the same lease cannot settle twice.
    assert_eq!(small.settle(&lease, b"again"), Err("lease_lost".to_string()));
    assert_eq!(small.metrics().lost_settles, 1);
}

#[test]
fn a_peer_offer_is_answered_from_the_load_now_not_from_its_beat() {
    let now = 1_000;
    let (mut small, _) = node("small", now);
    let (mut big, _) = node("big", now);
    see(&mut small, &big, now);
    small.set_load(80, 40);
    small.publish(now);
    let _ = small.next_call();
    let submission = small.submit("stt", b"audio".to_vec(), now).expect("submitted");
    let call = small.next_call().expect("the offer");
    let offer = Offer::decode(call.body.as_bytes()).expect("an offer");

    // The peer got busy after the beat the sender scored: it refuses on its load now.
    big.set_load(99, 40);
    assert_eq!(big.answer(&offer, now)["reason"], json!("busy"));
    // An offer addressed to someone else is refused by name.
    let mut elsewhere = offer.clone();
    elsewhere.to = NodeId::new("other").unwrap();
    assert_eq!(big.answer(&elsewhere, now)["reason"], json!("wrong_target"));
    // An offer whose window has closed is refused as late, not accepted on a stale beat.
    assert_eq!(big.answer(&offer, now + Config::default().offer_window_ms + 1)["reason"], json!("late"));
    let _ = submission;
}

#[test]
fn a_window_that_elapses_is_a_local_fallback_and_the_admin_view_says_so() {
    let now = 1_000;
    let (mut small, clock) = node("small", now);
    let (big, _) = node("big", now);
    see(&mut small, &big, now);
    small.set_load(80, 40);
    small.publish(now);
    let _ = small.next_call();
    let submission = small.submit("stt", b"audio".to_vec(), now).expect("submitted");
    assert!(small.next_call().is_some(), "the offer went out");

    let later = now + Config::default().offer_window_ms;
    clock.set(later);
    let tick = small.tick(later);
    assert_eq!(tick.local, vec![(submission.job.0, LocalReason::OfferWindowElapsed)]);
    assert_eq!(small.metrics().timeouts, 1);

    let view = small.admin("stt", later);
    assert_eq!(view["ok"], json!(true));
    assert_eq!(view["self"], json!("small"));
    assert_eq!(view["counters"]["timeouts"], json!(1));
    assert_eq!(view["counters"]["fallbacks"]["offer_window_elapsed"], json!(1));
    assert!(view["recent"].as_array().unwrap().iter().any(|record| record["outcome"] == json!("local")));
}

#[test]
fn the_process_surface_answers_configure_status_and_pending_on_one_thread() {
    let answer = configure(&json!({"self": "n1", "caps": ["stt", "ocr"]}));
    assert_eq!(answer["ok"], json!(true));
    assert_eq!(answer["self"], json!("n1"));
    assert_eq!(answer["caps"], json!(["ocr", "stt"]));

    let status = admin(&json!({"kind": "stt"}));
    assert_eq!(status["ok"], json!(true));
    assert_eq!(status["enabled"], json!(true));

    // An unusable id is refused by name, not by a panic.
    assert_eq!(configure(&json!({"self": ""}))["error"], json!("fabric_self_required"));
    assert_eq!(configure(&json!({"self": "bad id with spaces"}))["error"], json!("fabric_self_invalid"));

    assert!(pending().is_null(), "nothing to say with no peers");
    assert_eq!(tick()["ok"], json!(true));
    assert_eq!(deliver(9_999, "{\"unreachable\":\"relay\"}")["resolved"], json!({"ignored": "unknown_call"}));
    assert_eq!(deliver(9_999, "not json")["resolved"], json!({"ignored": "unreadable"}));
    // The payload is required: an empty submit is a refusal, not a job with no bytes.
    assert_eq!(submit(&json!({"kind": "stt"}))["error"], json!("fabric_payload_required"));
    assert_eq!(take(&json!({"kind": "stt"}))["job"], json!(null));
    assert_eq!(settle(&json!({"kind": "stt", "job": 1}))["error"], json!("lease_lost"));
}

#[test]
fn a_peer_call_is_admitted_only_for_the_node_the_transport_verified() {
    configure(&json!({"self": "n1", "caps": ["stt"]}));
    let (other, _) = node("n2", 1_000);
    let body = String::from_utf8(other.heartbeat(1_000).encode()).unwrap();
    // Claiming to be another node than the verified caller is a refusal.
    assert_eq!(call(&body, "n3")["refused"], json!("malformed:node"));
    assert_eq!(call(&body, "n2")["ok"], json!(true));
    let status = admin(&json!({"kind": "stt"}));
    let nodes = status["nodes"].as_array().expect("nodes");
    assert!(nodes.iter().any(|node| node["node"] == json!("n2")));
    // A body that is neither a heartbeat nor an offer is refused, never half-applied.
    assert_eq!(call("{\"v\":1}", "n2")["refused"], json!("malformed:kind"));
}

#[test]
fn capabilities_and_load_are_what_the_heartbeat_carries() {
    let (mut node, _) = node("n1", 1_000);
    node.set_caps(["stt", "embed"]);
    node.set_load(30, 40);
    let beat = node.heartbeat(1_000);
    assert!(beat.caps.covers(&Capabilities::of(["embed"])));
    assert_eq!(beat.load.cpu_busy_pct, 30);
    assert_eq!(beat.load.queue_depth, 0);
    // A queued job shows up in the published depth, because the depth is read from the queue.
    let _ = node.submit("stt", b"audio".to_vec(), 1_000);
    assert!(node.heartbeat(1_000).load.queue_depth >= 1);
    assert_eq!(Load::new(0, 200, 200), Load::new(0, 100, 100), "percentages are clamped");
}
