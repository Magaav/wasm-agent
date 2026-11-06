//! The bus host's own tests: the ACL built from manifests, the guest-facing publish/subscribe
//! shape, revocation on stop, and the alert topic the queue sweeper publishes to.
//!
//! A `BusHost::new()` per test, never the node singleton: a test must not inherit another test's
//! grants, and none of these touch a component directory (the bus has no store of its own unless a
//! retention namespace is enabled).

use super::*;
use serde_json::json;

fn host() -> BusHost {
    BusHost::new()
}

fn event(topic: &str, payload: &[u8]) -> GuestEvent {
    GuestEvent {
        id: 0,
        topic: topic.to_string(),
        ts_ms: 0,
        source: "a-guest-that-is-lying".to_string(),
        schema: "wa.test".to_string(),
        schema_version: 1,
        trace: None,
        payload: payload.to_vec(),
    }
}

fn options(capacity: u32) -> SubscribeOptions {
    SubscribeOptions::new().with_capacity(capacity as usize)
}

#[test]
fn a_grant_is_read_from_the_manifest_and_nothing_else() {
    let manifest = json!({"capabilities": {"bus": {"publish": ["whatsapp.out"], "subscribe": ["whatsapp.*"]}}});
    let grants = Grants::from_manifest(&manifest).unwrap();
    assert_eq!(grants.publish, vec!["whatsapp.out".to_string()]);
    assert_eq!(grants.subscribe, vec!["whatsapp.*".to_string()]);

    // No declaration is no grant: own namespace only, the library default.
    assert_eq!(Grants::from_manifest(&json!({})).unwrap(), Grants::default());

    // A malformed grant is an error, never a silent empty one.
    assert!(Grants::from_manifest(&json!({"capabilities": {"bus": "everything"}})).is_err());
    assert!(Grants::from_manifest(&json!({"capabilities": {"bus": {"publish": "a.b"}}})).is_err());
    // An invalid pattern is refused at registration, not at the first subscribe.
    let host = host();
    assert!(host.register("w", &json!({"capabilities": {"bus": {"publish": ["a..b"]}}})).is_err());
}

#[test]
fn a_component_without_a_grant_is_scoped_to_its_own_namespace() {
    let host = host();
    host.register("indexer", &json!({})).unwrap();
    // The library's ACL default: own namespace only, everything else denied.
    assert!(host.subscribe("indexer", "indexer.notes", options(8), None).is_ok());
    assert!(host.subscribe("indexer", "whatsapp.transcript", options(8), None).is_err());
    assert!(host.publish("indexer", event("indexer.self", b"x")).is_ok());
    assert!(host.publish("indexer", event("whatsapp.transcript", b"x")).is_err());
}

#[test]
fn a_grant_widens_and_a_stop_takes_it_away_again() {
    let host = host();
    let manifest = json!({"capabilities": {"bus": {"publish": ["whatsapp.transcript.ready"], "subscribe": ["whatsapp.*"]}}});
    host.register("wa-whatsapp", &manifest).unwrap();

    let sub = host.subscribe("wa-whatsapp", "whatsapp.*", options(8), None).unwrap();
    let report = host.publish("wa-whatsapp", event("whatsapp.transcript.ready", b"{}")).unwrap();
    assert_eq!((report.matched, report.delivered, report.dropped), (1, 1, 0));
    assert_eq!(sub.recv().map(|e| e.topic.as_str().to_string()).as_deref(), Some("whatsapp.transcript.ready"));

    // A stop revokes the subscriptions *and* the grants: the same call is refused afterwards.
    assert_eq!(host.unregister("wa-whatsapp"), 1);
    assert!(sub.is_closed(), "a revoked subscription yields nothing");
    assert_eq!(sub.recv(), None);
    assert!(host.subscribe("wa-whatsapp", "whatsapp.*", options(8), None).is_err());
}

#[test]
fn the_host_sets_the_source_and_ignores_what_the_guest_says_it_is() {
    let host = host();
    host.register("logger", &json!({})).unwrap();
    let sub = host.subscribe("logger", "logger.*", options(8), None).unwrap();
    let report = host.publish("logger", event("logger.line", b"hi")).unwrap();
    assert!(report.id > 0, "the bus assigns an id when the guest sends 0");
    let received = sub.recv().unwrap();
    assert_eq!(received.source, "logger", "the guest's `source` field is not trusted");
    assert_eq!(received.schema.name, "wa.test");
}

#[test]
fn a_replay_is_refused_where_the_topic_is_not_durable() {
    let host = host();
    host.register("agent", &json!({})).unwrap();
    let error = host.subscribe("agent", "agent.notes", options(8), Some(4)).unwrap_err();
    // Retention is per exact topic and off by default, so `replay` on a topic with none is refused.
    assert!(matches!(error, BusFault::Refused(_)), "{error:?}");
}

#[test]
fn node_facts_go_through_the_same_acl_and_carry_no_guest_text() {
    let host = host();
    host.register("kernel-ui", &json!({"capabilities": {"bus": {"subscribe": ["kernel.*"]}}})).unwrap();
    let sub = host.subscribe("kernel-ui", "kernel.*", options(8), None).unwrap();
    let report = host.publish_node_fact(QUEUE_ALERT_TOPIC, "wa.queue.alert", b"{\"queue\":\"wa.stt\"}".to_vec()).unwrap();
    assert_eq!(report.delivered, 1);
    let received = sub.recv().unwrap();
    assert_eq!(received.source, "kernel");
    assert_eq!(received.topic.as_str(), QUEUE_ALERT_TOPIC);
}

#[test]
fn status_carries_counts_and_patterns_but_no_payload() {
    let host = host();
    host.register("svc", &json!({"capabilities": {"bus": {"subscribe": ["svc.*"]}}})).unwrap();
    let _sub = host.subscribe("svc", "svc.*", options(8), None).unwrap();
    host.publish("svc", event("svc.self", b"a-secret-payload")).unwrap();
    let status = host.status().to_string();
    assert!(status.contains("svc.*"));
    assert!(!status.contains("a-secret-payload"), "status must never carry a payload");
}

#[test]
fn the_stream_survives_a_publish_that_arrives_before_the_guest_reads() {
    // The pump and the channel are what make `stream<event>` work; this is the part that can be
    // tested without a runtime: an event pushed into the channel is still there when the producer
    // is polled, and the channel is bounded.
    let host = host();
    host.register("reader", &json!({})).unwrap();
    let subscription = host.subscribe("reader", "reader.*", options(2), None).unwrap();
    let channel = pump(subscription, 2);
    host.publish("reader", event("reader.one", b"1")).unwrap();
    host.publish("reader", event("reader.two", b"2")).unwrap();
    host.publish("reader", event("reader.three", b"3")).unwrap();
    // Give the pump a moment to drain the library buffer into the channel.
    let start = std::time::Instant::now();
    while channel.queue.lock().unwrap().is_empty() && start.elapsed() < std::time::Duration::from_secs(2) {
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    let queued = channel.queue.lock().unwrap().len();
    assert!(queued >= 1 && queued <= 2, "bounded by the subscription's capacity, got {queued}");
    // Dropping the producer stops the pump, and the pump owns the subscription: unsubscribe.
    channel.stop.store(true, Ordering::Relaxed);
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
    while !channel.closed.load(Ordering::Relaxed) && std::time::Instant::now() < deadline {
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    assert!(channel.closed.load(Ordering::Relaxed), "the pump observed the stop");
}
