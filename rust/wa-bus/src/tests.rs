//! Unit tests for the bus: matching, revocation, overflow, ordering, durable catch-up, ACL.

use crate::access::{Access, Action, AllowAll, NamespaceAcl};
use crate::bus::{
    Bus, BusError, OverflowPolicy, SubscribeOptions, DEFAULT_CAPACITY,
};
use crate::event::{Event, EventId};
use crate::kv::MemoryKv;
use crate::topic::{Pattern, Topic};
use std::sync::Arc;
use std::time::Duration;

fn topic(s: &str) -> Topic {
    Topic::parse(s).unwrap_or_else(|e| panic!("topic {s:?}: {e}"))
}

fn ev(topic_str: &str, source: &str, payload: &str) -> Event {
    Event::new(topic(topic_str), source, "test.event", payload.as_bytes().to_vec())
}

fn bus() -> Bus {
    Bus::new()
}

fn allow_all() -> Bus {
    Bus::with_access(Arc::new(AllowAll))
}

// ---- topics and patterns ---------------------------------------------------------------------------

#[test]
fn topics_are_validated_and_namespaced() {
    let t = topic("whatsapp.transcript.ready");
    assert_eq!(t.namespace(), "whatsapp");
    assert_eq!(t.segments().collect::<Vec<_>>(), vec!["whatsapp", "transcript", "ready"]);
    assert_eq!(topic("wa-whatsapp.a_b").namespace(), "wa-whatsapp");

    for bad in [
        "",
        ".",
        "a..b",
        ".a",
        "a.",
        "a b",
        "a*b",
        "a/b",
        "a#b",
        "-a",
        "a-",
        "A.b", // uppercase is allowed; keep it in the accepted list below, this one is a control
    ] {
        let got = Topic::parse(bad);
        if bad == "A.b" {
            assert!(got.is_ok(), "uppercase must be accepted");
        } else {
            assert!(got.is_err(), "{bad:?} must be refused");
        }
    }

    let long_segment = "a".repeat(crate::MAX_SEGMENT + 1);
    assert!(Topic::parse(&long_segment).is_err());
    let many = vec!["a"; crate::MAX_SEGMENTS + 1].join(".");
    assert!(Topic::parse(&many).is_err());
}

#[test]
fn wildcard_matching_is_prefix_at_a_segment_boundary() {
    let prefix = Pattern::parse("whatsapp.*").unwrap();
    assert!(prefix.matches(&topic("whatsapp.transcript.ready")));
    assert!(prefix.matches(&topic("whatsapp.transcript")));
    assert!(!prefix.matches(&topic("whatsapp")));
    assert!(!prefix.matches(&topic("whatsappx.transcript")));

    let exact = Pattern::parse("whatsapp.transcript.ready").unwrap();
    assert!(exact.matches(&topic("whatsapp.transcript.ready")));
    assert!(!exact.matches(&topic("whatsapp.transcript")));

    let all = Pattern::parse("*").unwrap();
    assert!(all.matches(&topic("anything.at.all")));

    for bad in ["a*b", "a.*.b", "*.a", "a.b*"] {
        assert!(Pattern::parse(bad).is_err(), "{bad:?} must be refused");
    }
    assert_eq!(Pattern::parse("a.b.*").unwrap().as_written(), "a.b.*");
    assert_eq!(Pattern::parse("*").unwrap().as_written(), "*");
    assert_eq!(Pattern::parse("a.b").unwrap().as_written(), "a.b");
}

#[test]
fn a_pattern_covers_only_what_is_inside_it() {
    let wide = Pattern::parse("whatsapp.*").unwrap();
    let narrow = Pattern::parse("whatsapp.transcript.*").unwrap();
    let other = Pattern::parse("telegram.*").unwrap();
    assert!(wide.covers(&narrow));
    assert!(wide.covers(&Pattern::parse("whatsapp.transcript.ready").unwrap()));
    assert!(!narrow.covers(&wide));
    assert!(!wide.covers(&other));
    assert!(!wide.covers(&Pattern::parse("*").unwrap()));
    assert!(Pattern::parse("*").unwrap().covers(&wide));
}

// ---- envelope ---------------------------------------------------------------------------------------

#[test]
fn the_envelope_round_trips_through_its_stored_form() {
    let e = ev("whatsapp.transcript.ready", "whatsapp", "payload bytes")
        .with_id(EventId(42))
        .with_ts(1_700_000_000_123)
        .with_schema_version(3)
        .with_trace("trace-abc");
    let bytes = e.encode();
    assert_eq!(Event::decode(&bytes).unwrap(), e);

    // Empty payload and no trace are legal and distinct from "trace id empty string".
    let bare = Event::new(topic("a.b"), "a", "s", Vec::new());
    assert_eq!(Event::decode(&bare.encode()).unwrap(), bare);
    assert!(bare.trace.is_none());
    let empty_trace = bare.clone().with_trace("");
    assert_ne!(Event::decode(&empty_trace.encode()).unwrap(), bare);
}

#[test]
fn a_corrupt_or_truncated_record_is_an_error_not_a_short_event() {
    let e = ev("a.b", "a", "hello").with_id(EventId(1)).with_ts(5);
    let bytes = e.encode();
    assert!(Event::decode(&bytes[..bytes.len() - 1]).is_err());
    assert!(Event::decode(&[]).is_err());

    let mut bad_magic = bytes.clone();
    bad_magic[0] = b'X';
    assert!(Event::decode(&bad_magic).is_err());

    let mut format = bytes.clone();
    format[6] = 9;
    assert!(Event::decode(&format).is_err());

    let mut trailing = bytes.clone();
    trailing.push(0);
    assert!(Event::decode(&trailing).is_err());
}

#[test]
fn a_summary_never_carries_the_payload() {
    let e = ev("whatsapp.transcript.ready", "whatsapp", "secret message text")
        .with_id(EventId(7))
        .with_trace("t-1");
    let line = e.summary();
    assert!(!line.contains("secret"), "summary must not leak payload: {line}");
    assert!(line.contains("topic=whatsapp.transcript.ready"));
    assert!(line.contains("source=whatsapp"));
    assert!(line.contains("bytes=19"), "{line}");
    assert!(line.contains("trace=t-1"));
}

// ---- delivery: fan-out, ordering --------------------------------------------------------------------

#[test]
fn facts_fan_out_to_every_matching_subscriber() {
    let bus = allow_all();
    let exact = bus
        .subscribe("agent", "whatsapp.transcript.ready", SubscribeOptions::new())
        .unwrap();
    let prefix = bus.subscribe("index", "whatsapp.*", SubscribeOptions::new()).unwrap();
    let other = bus.subscribe("logger", "telegram.*", SubscribeOptions::new()).unwrap();

    let outcome = bus.publish(ev("whatsapp.transcript.ready", "whatsapp", "x")).unwrap();
    assert_eq!(outcome.matched, 2);
    assert_eq!(outcome.delivered, 2);
    assert!(outcome.complete());
    assert_eq!(exact.recv().unwrap().topic.as_str(), "whatsapp.transcript.ready");
    assert_eq!(prefix.recv().unwrap().topic.as_str(), "whatsapp.transcript.ready");
    assert!(other.recv().is_none());
    assert!(bus.subscriptions().iter().any(|s| s.owner == "index" && s.pattern == "whatsapp.*"));
}

#[test]
fn a_publish_with_no_subscriber_is_not_an_error() {
    let bus = allow_all();
    let outcome = bus.publish(ev("a.b", "a", "x")).unwrap();
    assert_eq!(outcome.matched, 0);
    assert_eq!(outcome.delivered, 0);
    assert!(outcome.complete());
}

#[test]
fn order_is_preserved_per_topic_and_per_subscriber() {
    let bus = allow_all();
    let sub = bus
        .subscribe("index", "whatsapp.*", SubscribeOptions::new().with_capacity(16))
        .unwrap();
    let exact = bus
        .subscribe("agent", "whatsapp.transcript.ready", SubscribeOptions::new())
        .unwrap();

    let mut expected = Vec::new();
    for i in 0..5 {
        let t = if i % 2 == 0 { "whatsapp.transcript.ready" } else { "whatsapp.transcript.failed" };
        let e = ev(t, "whatsapp", &format!("e{i}"));
        expected.push((t.to_string(), format!("e{i}")));
        bus.publish(e).unwrap();
    }

    let got: Vec<(String, String)> = sub
        .drain(0)
        .into_iter()
        .map(|e| (e.topic.as_str().to_string(), String::from_utf8(e.payload).unwrap()))
        .collect();
    assert_eq!(got, expected, "fan-out keeps publish order");

    let only_ready: Vec<String> = exact
        .drain(0)
        .into_iter()
        .map(|e| String::from_utf8(e.payload).unwrap())
        .collect();
    assert_eq!(only_ready, vec!["e0", "e2", "e4"], "an exact subscription sees only its topic");
}

#[test]
fn ids_are_monotonic_and_an_explicit_id_is_kept() {
    let bus = allow_all();
    let a = bus.publish(ev("a.b", "a", "1")).unwrap().id;
    let b = bus.publish(ev("a.b", "a", "2")).unwrap().id;
    assert!(a.0 < b.0);
    let explicit = bus.publish(ev("a.b", "a", "3").with_id(EventId(9_000))).unwrap().id;
    assert_eq!(explicit, EventId(9_000));
    // An id the caller chose is never handed out again: the counter moves past it.
    assert_eq!(bus.publish(ev("a.b", "a", "4")).unwrap().id, EventId(9_001));
}

#[test]
fn a_publish_stamps_an_unset_timestamp() {
    let bus = allow_all();
    let before = crate::now_ms();
    let e = bus.publish(ev("a.b", "a", "x").with_ts(0)).unwrap();
    assert!(e.id.is_assigned());
    let sub = bus.subscribe("a", "a.b", SubscribeOptions::new()).unwrap();
    bus.publish(ev("a.b", "a", "y").with_ts(0)).unwrap();
    let got = sub.recv().unwrap();
    assert!(got.ts_ms >= before, "{} < {before}", got.ts_ms);
}

// ---- delivery: overflow ----------------------------------------------------------------------------

#[test]
fn drop_oldest_keeps_the_present_and_counts_the_loss() {
    let bus = allow_all();
    let sub = bus
        .subscribe(
            "logger",
            "a.b",
            SubscribeOptions::new().with_capacity(2).with_policy(OverflowPolicy::DropOldest),
        )
        .unwrap();
    for i in 0..4 {
        let outcome = bus.publish(ev("a.b", "a", &format!("e{i}"))).unwrap();
        assert_eq!(outcome.delivered, 1);
        assert_eq!(outcome.dropped, usize::from(i >= 2), "overflows are reported to the producer");
    }
    assert_eq!(sub.dropped(), 2);
    let payloads: Vec<String> =
        sub.drain(0).into_iter().map(|e| String::from_utf8(e.payload).unwrap()).collect();
    assert_eq!(payloads, vec!["e2", "e3"], "the newest events are the ones kept");
}

#[test]
fn drop_newest_keeps_the_queued_snapshot_and_counts_the_loss() {
    let bus = allow_all();
    let sub = bus
        .subscribe(
            "agent",
            "a.b",
            SubscribeOptions::new().with_capacity(2).with_policy(OverflowPolicy::DropNewest),
        )
        .unwrap();
    for i in 0..4 {
        bus.publish(ev("a.b", "a", &format!("e{i}"))).unwrap();
    }
    assert_eq!(sub.dropped(), 2);
    let payloads: Vec<String> =
        sub.drain(0).into_iter().map(|e| String::from_utf8(e.payload).unwrap()).collect();
    assert_eq!(payloads, vec!["e0", "e1"]);
}

#[test]
fn block_refuses_instead_of_dropping_and_says_so() {
    let bus = allow_all();
    let sub = bus
        .subscribe(
            "index",
            "a.b",
            SubscribeOptions::new().with_capacity(1).with_policy(OverflowPolicy::Block),
        )
        .unwrap();
    assert!(bus.publish(ev("a.b", "a", "first")).unwrap().complete());
    let outcome = bus.publish(ev("a.b", "a", "second")).unwrap();
    assert!(!outcome.accepted_by_all());
    assert_eq!(outcome.blocked, vec![sub.id()]);
    assert_eq!(outcome.delivered, 0);
    assert_eq!(outcome.dropped, 0, "blocking never drops");
    assert_eq!(sub.dropped(), 0);
    assert_eq!(sub.blocked(), 1);

    // The buffer still holds the first event, in order; the refused one is not there.
    assert_eq!(
        sub.drain(0).into_iter().map(|e| String::from_utf8(e.payload).unwrap()).collect::<Vec<_>>(),
        vec!["first"]
    );
    // And with space free the same event would be delivered.
    assert!(bus.publish(ev("a.b", "a", "third")).unwrap().complete());
    assert_eq!(String::from_utf8(sub.recv().unwrap().payload).unwrap(), "third");
}

#[test]
fn a_blocking_publish_waits_for_a_consumer_and_loses_nothing() {
    let bus = allow_all();
    let sub = bus
        .subscribe(
            "index",
            "a.b",
            SubscribeOptions::new().with_capacity(1).with_policy(OverflowPolicy::Block),
        )
        .unwrap();
    bus.publish(ev("a.b", "a", "e1")).unwrap();

    let (tx, rx) = std::sync::mpsc::channel();
    let consumer = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(80));
        let first = String::from_utf8(sub.recv().unwrap().payload).unwrap();
        // The buffer is free now; the producer's blocked publish must land here.
        std::thread::sleep(Duration::from_millis(80));
        let second = String::from_utf8(sub.recv().unwrap().payload).unwrap();
        tx.send((first, second)).unwrap();
        // Keep the handle alive until the end of the test.
        sub
    });

    let outcome = bus.publish_blocking(ev("a.b", "a", "e2"), Duration::from_secs(5)).unwrap();
    assert!(outcome.accepted_by_all(), "the producer waited instead of dropping: {outcome:?}");
    assert_eq!(outcome.delivered, 1);
    assert_eq!(outcome.dropped, 0);

    let (first, second) = rx.recv_timeout(Duration::from_secs(5)).unwrap();
    assert_eq!((first.as_str(), second.as_str()), ("e1", "e2"), "FIFO across the wait");
    let sub = consumer.join().unwrap();
    drop(sub);
}

#[test]
fn a_blocking_publish_gives_up_at_its_deadline_without_dropping() {
    let bus = allow_all();
    let sub = bus
        .subscribe(
            "index",
            "a.b",
            SubscribeOptions::new().with_capacity(1).with_policy(OverflowPolicy::Block),
        )
        .unwrap();
    bus.publish(ev("a.b", "a", "e1")).unwrap();
    let started = std::time::Instant::now();
    let outcome = bus.publish_blocking(ev("a.b", "a", "e2"), Duration::from_millis(120)).unwrap();
    assert!(started.elapsed() >= Duration::from_millis(100), "it should actually wait");
    assert_eq!(outcome.blocked, vec![sub.id()]);
    assert_eq!(sub.dropped(), 0);
    assert_eq!(sub.blocked(), 1);
    assert_eq!(String::from_utf8(sub.recv().unwrap().payload).unwrap(), "e1");
}

// ---- revocation --------------------------------------------------------------------------------------

#[test]
fn revoking_an_owner_stops_its_subscriptions_and_no_one_else_s() {
    let bus = allow_all();
    let whatsapp = bus.subscribe("whatsapp", "whatsapp.*", SubscribeOptions::new()).unwrap();
    let index = bus.subscribe("index", "whatsapp.*", SubscribeOptions::new()).unwrap();

    assert_eq!(bus.revoke_owner("whatsapp"), 1);
    assert!(whatsapp.is_closed());
    assert!(whatsapp.recv().is_none(), "a revoked handle yields nothing");
    assert!(!whatsapp.close(), "closing twice is a no-op");

    let outcome = bus.publish(ev("whatsapp.transcript.ready", "whatsapp", "x")).unwrap();
    assert_eq!(outcome.matched, 1, "only the surviving subscription matches");
    assert_eq!(outcome.delivered, 1);
    assert!(index.recv().is_some());
    assert_eq!(bus.revoke_owner("nobody"), 0);
}

#[test]
fn dropping_the_handle_unsubscribes() {
    let bus = allow_all();
    let sub = bus.subscribe("index", "a.*", SubscribeOptions::new()).unwrap();
    assert_eq!(bus.subscriber_count(), 1);
    drop(sub);
    assert_eq!(bus.subscriber_count(), 0);
    assert_eq!(bus.publish(ev("a.b", "a", "x")).unwrap().matched, 0);
}

#[test]
fn revoke_all_clears_the_bus() {
    let bus = allow_all();
    let _a = bus.subscribe("a", "a.*", SubscribeOptions::new()).unwrap();
    let _b = bus.subscribe("b", "b.*", SubscribeOptions::new()).unwrap();
    assert_eq!(bus.revoke_all(), 2);
    assert_eq!(bus.subscriber_count(), 0);
    assert!(bus.subscriptions().is_empty());
}

// ---- access control ----------------------------------------------------------------------------------

#[test]
fn own_namespace_by_default_and_everything_else_denied() {
    let bus = bus(); // default policy
    assert!(bus.publish(ev("whatsapp.transcript.ready", "whatsapp", "x")).is_ok());
    assert!(bus.subscribe("whatsapp", "whatsapp.*", SubscribeOptions::new()).is_ok());
    assert!(bus.subscribe("whatsapp", "whatsapp.transcript.ready", SubscribeOptions::new()).is_ok());

    match bus.publish(ev("whatsapp.transcript.ready", "agent", "x")) {
        Err(BusError::Denied { component, action, subject }) => {
            assert_eq!((component.as_str(), action), ("agent", "publish"));
            assert_eq!(subject, "whatsapp.transcript.ready");
        }
        other => panic!("expected a deny, got {other:?}"),
    }
    assert!(matches!(
        bus.subscribe("agent", "whatsapp.*", SubscribeOptions::new()),
        Err(BusError::Denied { .. })
    ));
    // Broader than your own namespace is denied too.
    assert!(matches!(
        bus.subscribe("whatsapp", "*", SubscribeOptions::new()),
        Err(BusError::Denied { .. })
    ));
    assert!(matches!(
        bus.subscribe("whatsapp", "whatsappx.*", SubscribeOptions::new()),
        Err(BusError::Denied { .. })
    ));
}

#[test]
fn a_grant_opens_exactly_the_door_it_names() {
    let mut acl = NamespaceAcl::new();
    acl.grant("index", Action::Subscribe, "whatsapp.*").unwrap();
    let bus = Bus::with_access(Arc::new(acl));

    assert!(bus.subscribe("index", "whatsapp.*", SubscribeOptions::new()).is_ok());
    // Narrower than the grant is inside it.
    assert!(bus.subscribe("index", "whatsapp.transcript.*", SubscribeOptions::new()).is_ok());
    // Broader is not.
    assert!(matches!(
        bus.subscribe("index", "*", SubscribeOptions::new()),
        Err(BusError::Denied { .. })
    ));
    // A subscribe grant is not a publish grant.
    assert!(matches!(
        bus.publish(ev("whatsapp.transcript.ready", "index", "x")),
        Err(BusError::Denied { .. })
    ));
    // And a denied publish delivered nothing to the granted subscriber.
    assert!(bus.publish(ev("whatsapp.transcript.ready", "whatsapp", "x")).is_ok());
}

#[test]
fn a_publish_grant_can_name_one_topic_or_a_prefix() {
    let mut acl = NamespaceAcl::new();
    acl.grant("transcriber", Action::Publish, "whatsapp.transcript.ready").unwrap();
    acl.grant("logger", Action::Publish, "whatsapp.*").unwrap();
    let bus = Bus::with_access(Arc::new(acl.clone()));

    assert!(bus.publish(ev("whatsapp.transcript.ready", "transcriber", "x")).is_ok());
    assert!(matches!(
        bus.publish(ev("whatsapp.transcript.failed", "transcriber", "x")),
        Err(BusError::Denied { .. })
    ));
    assert!(bus.publish(ev("whatsapp.transcript.failed", "logger", "x")).is_ok());
    assert!(matches!(
        bus.publish(ev("telegram.message", "logger", "x")),
        Err(BusError::Denied { .. })
    ));
    assert_eq!(acl.describe().len(), 2);
}

#[test]
fn a_host_can_replace_the_policy_at_runtime() {
    let bus = bus();
    assert!(bus.subscribe("agent", "whatsapp.*", SubscribeOptions::new()).is_err());
    let mut acl = NamespaceAcl::new();
    acl.grant("agent", Action::Subscribe, "whatsapp.*").unwrap();
    bus.set_access(Arc::new(acl));
    assert!(bus.subscribe("agent", "whatsapp.*", SubscribeOptions::new()).is_ok());
}

/// A host policy that is not the namespace one: here, the only component allowed anything is
/// `audit`, and only as a subscriber. Proves the hook is a trait, not a hard-coded rule.
struct AuditOnly;

impl Access for AuditOnly {
    fn may_publish(&self, _source: &str, _topic: &Topic) -> bool {
        false
    }
    fn may_subscribe(&self, owner: &str, _pattern: &Pattern) -> bool {
        owner == "audit"
    }
}

#[test]
fn a_custom_access_policy_is_honoured() {
    let bus = Bus::with_access(Arc::new(AuditOnly));
    assert!(bus.subscribe("audit", "any.thing", SubscribeOptions::new()).is_ok());
    assert!(bus.subscribe("index", "any.thing", SubscribeOptions::new()).is_err());
    assert!(bus.publish(ev("any.thing", "audit", "x")).is_err());
}

// ---- durable topics ------------------------------------------------------------------------------------

#[test]
fn a_late_subscriber_catches_up_on_a_durable_topic() {
    let bus = allow_all();
    let kv = Arc::new(MemoryKv::new());
    bus.enable_durable("whatsapp.transcript.ready", 3, kv.clone()).unwrap();
    assert_eq!(bus.durable_topics(), vec![("whatsapp.transcript.ready".to_string(), 3)]);

    let mut ids = Vec::new();
    for i in 0..5 {
        ids.push(bus.publish(ev("whatsapp.transcript.ready", "whatsapp", &format!("e{i}"))).unwrap().id);
    }
    assert_eq!(kv.len(), 3, "retention trims to the last N");

    let late = bus
        .subscribe_replaying(
            "index",
            "whatsapp.transcript.ready",
            SubscribeOptions::new().with_capacity(8),
            10,
        )
        .unwrap();
    assert_eq!(late.replayed(), 3);
    let got: Vec<(EventId, String)> = late
        .drain(0)
        .into_iter()
        .map(|e| (e.id, String::from_utf8(e.payload).unwrap()))
        .collect();
    assert_eq!(got, vec![(ids[2], "e2".to_string()), (ids[3], "e3".to_string()), (ids[4], "e4".to_string())]);

    // Live delivery continues in order after the catch-up.
    bus.publish(ev("whatsapp.transcript.ready", "whatsapp", "e5")).unwrap();
    assert_eq!(String::from_utf8(late.recv().unwrap().payload).unwrap(), "e5");
}

#[test]
fn catch_up_keeps_the_newest_events_that_fit_the_buffer() {
    let bus = allow_all();
    bus.enable_durable("a.b", 5, Arc::new(MemoryKv::new())).unwrap();
    for i in 0..5 {
        bus.publish(ev("a.b", "a", &format!("e{i}"))).unwrap();
    }
    let sub = bus
        .subscribe_replaying("agent", "a.b", SubscribeOptions::new().with_capacity(2), 10)
        .unwrap();
    assert_eq!(sub.replayed(), 2);
    let payloads: Vec<String> =
        sub.drain(0).into_iter().map(|e| String::from_utf8(e.payload).unwrap()).collect();
    assert_eq!(payloads, vec!["e3", "e4"]);
}

#[test]
fn retention_survives_a_restart_of_the_bus() {
    let kv = Arc::new(MemoryKv::new());
    let first = allow_all();
    first.enable_durable("a.b", 4, kv.clone()).unwrap();
    first.publish(ev("a.b", "a", "e1").with_ts(1_000)).unwrap();
    first.publish(ev("a.b", "a", "e2").with_ts(2_000)).unwrap();
    drop(first);

    let second = allow_all();
    second.enable_durable("a.b", 4, kv.clone()).unwrap();
    let retained: Vec<String> = second
        .retained("a.b", 0)
        .unwrap()
        .into_iter()
        .map(|e| String::from_utf8(e.payload).unwrap())
        .collect();
    assert_eq!(retained, vec!["e1", "e2"], "key order is time order, so a new process replays old events");

    let sub = second
        .subscribe_replaying("agent", "a.b", SubscribeOptions::new().with_capacity(4), 4)
        .unwrap();
    assert_eq!(sub.replayed(), 2);
}

#[test]
fn catch_up_is_refused_where_it_cannot_be_honoured() {
    let bus = allow_all();
    assert!(matches!(
        bus.subscribe_replaying("agent", "a.b", SubscribeOptions::new(), 5),
        Err(BusError::ReplayNotDurable(_))
    ));
    bus.enable_durable("a.b", 2, Arc::new(MemoryKv::new())).unwrap();
    // A wildcard has no single retention log, so catch-up is only offered per topic.
    assert!(matches!(
        bus.subscribe_with("agent", Pattern::parse("a.*").unwrap(), SubscribeOptions::new(), Some(5)),
        Err(BusError::ReplayNeedsExactTopic(_))
    ));
    assert!(matches!(bus.enable_durable("a.b", 0, Arc::new(MemoryKv::new())), Err(BusError::BadOptions(_))));
}

#[test]
fn a_durable_topic_still_fans_out_live() {
    let bus = allow_all();
    bus.enable_durable("a.b", 8, Arc::new(MemoryKv::new())).unwrap();
    let one = bus.subscribe("agent", "a.b", SubscribeOptions::new()).unwrap();
    let two = bus.subscribe("logger", "a.*", SubscribeOptions::new()).unwrap();
    let outcome = bus.publish(ev("a.b", "a", "x")).unwrap();
    assert_eq!((outcome.matched, outcome.delivered), (2, 2));
    assert!(one.recv().is_some());
    assert!(two.recv().is_some());
    bus.disable_durable("a.b");
    assert!(bus.durable_topics().is_empty());
    assert!(bus.publish(ev("a.b", "a", "y")).is_ok());
}

// ---- defaults ------------------------------------------------------------------------------------------

#[test]
fn defaults_are_sane() {
    let options = SubscribeOptions::default();
    assert_eq!(options.capacity, DEFAULT_CAPACITY);
    assert_eq!(options.policy, OverflowPolicy::DropOldest);
    assert_eq!(crate::DEFAULT_RETAIN, 32);
    assert_eq!(OverflowPolicy::Block.as_str(), "block");
    assert!(Bus::default().subscriptions().is_empty());
}

#[test]
fn a_subscription_cannot_have_a_zero_sized_buffer() {
    let bus = allow_all();
    assert!(matches!(
        bus.subscribe("a", "a.b", SubscribeOptions::new().with_capacity(0)),
        Err(BusError::BadOptions(_))
    ));
}
