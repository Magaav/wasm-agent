//! The adapter's own tests: the namespace boundary, ordering and paging, and one real exercise of
//! each of the three library traits over the same store.
//!
//! They are written against `MemoryStore` (no file, no SQLite), because what is being tested here is
//! the adapter and not the host's database. The host's SQLite `Store` is tested where it lives
//! (`rust/wa-kernel-runtime/src/state_host.rs`).

use super::*;
use std::sync::Arc;

fn store() -> Arc<MemoryStore> {
    Arc::new(MemoryStore::new())
}

#[test]
fn two_namespaces_cannot_see_each_other() {
    let store = store();
    let a = Namespaced::new(store.clone(), "alpha/");
    let b = Namespaced::new(store.clone(), "beta/");
    a.put(b"k", b"a-value").unwrap();
    b.put(b"k", b"b-value").unwrap();

    assert_eq!(a.get(b"k").unwrap().as_deref(), Some(&b"a-value"[..]));
    assert_eq!(b.get(b"k").unwrap().as_deref(), Some(&b"b-value"[..]));
    assert_eq!(a.scan_prefix(b"").unwrap().len(), 1);
    assert_eq!(b.scan_prefix(b"").unwrap().len(), 1);
    // Keys are stripped on the way up, so a library never sees the host's prefix.
    assert_eq!(a.keys().unwrap(), vec![b"k".to_vec()]);
    // And the physical layout is what the module doc promises.
    assert_eq!(store.keys(), vec![b"alpha/k".to_vec(), b"beta/k".to_vec()]);
}

#[test]
fn a_child_namespace_is_heads_down() {
    let store = store();
    let component = Namespaced::new(store.clone(), "svc/");
    let queue = component.child("q/");
    let bus = component.child("b/");
    component.put(b"own", b"1").unwrap();
    queue.put(b"j/\x001", b"job").unwrap();
    bus.put(b"v1/topic/1", b"event").unwrap();

    assert!(queue.get(b"own").unwrap().is_none(), "a queue cannot read the component's own keys");
    assert!(bus.get(b"j/\x001").unwrap().is_none(), "bus retention is not the queue's namespace");
    assert_eq!(queue.keys().unwrap(), vec![b"j/\x001".to_vec()]);
    assert_eq!(component.get(b"j/\x001").unwrap(), None);
    // Deleting a namespace prefix reaches only that namespace.
    assert_eq!(queue.delete_prefix(b"j/").unwrap(), 1);
    assert_eq!(queue.keys().unwrap().len(), 0);
    assert_eq!(bus.keys().unwrap().len(), 1);
}

#[test]
fn scans_are_ordered_and_paged() {
    let store = store();
    let ns = Namespaced::new(store.clone(), "p/");
    // More keys than one page (PAGE is 512), inserted in a shuffled order.
    let mut keys: Vec<Vec<u8>> = (0..1200u32).map(|n| format!("i/{n:06}").into_bytes()).collect();
    keys.rotate_left(700);
    for key in &keys {
        ns.put(key, b"v").unwrap();
    }
    let mut expected = keys.clone();
    expected.sort();

    let all = ns.scan_prefix(b"i/").unwrap();
    assert_eq!(all.len(), 1200, "a prefix larger than one page is still complete");
    assert_eq!(all.iter().map(|(k, _)| k.clone()).collect::<Vec<_>>(), expected);

    // The same answer, page by page, through the cursor shape the host store and `wa:kernel/kv` use.
    let mut paged = Vec::new();
    let mut cursor: Option<Vec<u8>> = None;
    loop {
        let page = ns.scan_page(b"i/", cursor.as_deref(), 100).unwrap();
        let short = page.len() < 100;
        if let Some((key, _)) = page.last() {
            cursor = Some(key.clone());
        }
        paged.extend(page.into_iter().map(|(k, _)| k));
        if short {
            break;
        }
    }
    assert_eq!(paged, expected);
}

#[test]
fn a_scan_does_not_cross_the_prefix_boundary() {
    let store = store();
    let ns = Namespaced::new(store.clone(), "a/");
    // `ab/...` shares the first bytes with the prefix; it must not appear in `a/`'s scan.
    store.put(b"a/x", b"1").unwrap();
    store.put(b"ab/x", b"2").unwrap();
    store.put(b"b/x", b"3").unwrap();
    let entries = ns.scan_prefix(b"").unwrap();
    assert_eq!(entries, vec![(b"x".to_vec(), b"1".to_vec())]);
}

// ---- wa-queue over the adapter ---------------------------------------------------------------------

#[test]
fn the_queue_runs_on_the_adapter() {
    use wa_queue::{EnqueueRequest, JobState, Policy, Queue, TakeOutcome};

    let store = store();
    let queue = Queue::new(
        Arc::new(Namespaced::new(store.clone(), "svc/q/")),
        Arc::new(wa_queue::FixedClock::new(1_000_000)),
        Policy::default(),
    );

    let first = queue.enqueue(EnqueueRequest::new("wa.stt", b"audio-1".to_vec()).dedupe("a/1")).unwrap();
    let second = queue.enqueue(EnqueueRequest::new("wa.stt", b"audio-1".to_vec()).dedupe("a/1")).unwrap();
    assert!(second.dedupe_hit, "the dedupe claim lives in the store, so a second producer is deduped");
    assert_eq!(first.id, second.id);

    let leased = match queue.take("wa.stt", "worker-1", None).unwrap() {
        TakeOutcome::Job(job) => job,
        other => panic!("expected a job, got {other:?}"),
    };
    assert_eq!(leased.state, JobState::Leased);
    let done = queue.done_by(leased.id, "worker-1", b"transcript").unwrap();
    assert_eq!(done.state, JobState::Done);

    // Everything the queue wrote is under its own prefix, nowhere else, and it really wrote
    // records, not just a counter.
    let keys = store.keys();
    assert!(keys.iter().all(|key| key.starts_with(b"svc/q/")), "{keys:?}");
    // `q/` + the crate's own key space: a job record, a dedupe claim and a counter/id map.
    assert!(keys.iter().any(|key| key.starts_with(b"svc/q/j")), "{keys:?}");
    assert!(keys.iter().any(|key| key.starts_with(b"svc/q/d")), "{keys:?}");
    assert!(keys.len() >= 3, "{keys:?}");
}

#[test]
fn the_queue_survives_a_restart_over_the_same_bytes() {
    use wa_queue::{EnqueueRequest, Policy, Queue, TakeOutcome};

    let store = store();
    let namespace = || Arc::new(Namespaced::new(store.clone(), "svc/q/"));
    let clock = Arc::new(wa_queue::FixedClock::new(2_000_000));
    {
        let queue = Queue::new(namespace(), clock.clone(), Policy::default());
        queue.enqueue(EnqueueRequest::new("wa.post", b"hello".to_vec())).unwrap();
    }
    // A "restart": a new Queue over the same store, with the clock moved past the lease.
    clock.advance(120_000);
    let queue = Queue::new(namespace(), clock.clone(), Policy::default());
    assert_eq!(queue.stats("wa.post").unwrap().ready, 1);
    assert!(matches!(queue.take("wa.post", "worker-2", None).unwrap(), TakeOutcome::Job(_)));
}

// ---- wa-bus durable topics over the adapter ---------------------------------------------------------

#[test]
fn bus_retention_runs_on_the_adapter() {
    use wa_bus::{Bus, SubscribeOptions, Topic};

    let store = store();
    // Own-namespace-only is the bus default, so the late consumer needs a grant - which is the path
    // a manifest grant takes (`docs/BUS.md`, "Access control").
    let mut acl = wa_bus::NamespaceAcl::new();
    acl.grant("agent", wa_bus::Action::Subscribe, "kernel.queue.alert").unwrap();
    let bus = Bus::with_access(Arc::new(acl));
    bus.enable_durable(
        "kernel.queue.alert",
        4,
        Arc::new(Namespaced::new(store.clone(), "svc/b/")),
    )
    .unwrap();

    for n in 0..3u32 {
        let mut event = wa_bus::Event::new(
            Topic::parse("kernel.queue.alert").unwrap(),
            "kernel",
            "wa.queue.alert",
            format!("{{\"n\":{n}}}").into_bytes(),
        );
        event.ts_ms = 1_000 + n as u64;
        bus.publish(event).unwrap();
    }
    assert_eq!(bus.retained("kernel.queue.alert", 10).unwrap().len(), 3);

    // Retention is trimmed to the last N, and it is all under the bus prefix.
    for n in 3..8u32 {
        let mut event = wa_bus::Event::new(
            Topic::parse("kernel.queue.alert").unwrap(),
            "kernel",
            "wa.queue.alert",
            format!("{{\"n\":{n}}}").into_bytes(),
        );
        event.ts_ms = 1_000 + n as u64;
        bus.publish(event).unwrap();
    }
    let retained = bus.retained("kernel.queue.alert", 10).unwrap();
    assert_eq!(retained.len(), 4);
    assert_eq!(retained.last().unwrap().payload, b"{\"n\":7}");
    assert!(store.keys().iter().all(|key| key.starts_with(b"svc/b/v1/")));

    // A late consumer replays the retained tail through the same namespace.
    let late = bus
        .subscribe_replaying("agent", "kernel.queue.alert", SubscribeOptions::new().with_capacity(8), 8)
        .unwrap();
    assert_eq!(late.drain(0).len(), 4);
}

// ---- wa-state over the adapter ----------------------------------------------------------------------

#[test]
fn state_migrates_inside_its_namespace() {
    use wa_state::{meta, Batch, ComponentInfo, Kv as _, Migrator, Registry, Step};

    let store = store();
    let mut kv = Namespaced::new(store.clone(), "svc/");
    let info = ComponentInfo::new("svc", "1.0.0", &"a".repeat(64)).unwrap();

    // A fresh namespace is opened at the schema version the component writes natively, *then* the
    // component writes its v1 shape: `open` refuses to adopt keys that have no metadata, which is
    // the "one namespace, one owner, one version" rule (`docs/STATE.md`).
    let meta = meta::open(&mut kv, &info, 1, 1_000).unwrap();
    assert_eq!(meta.schema_version, 1);
    kv.put(b"m/one", b"1").unwrap();
    kv.put(b"m/two", b"2").unwrap();

    let registry = Registry::new(vec![Step::new(1, "messages/prefix", |batch: &mut Batch| {
        batch.rename_prefix(b"m/", b"msg/")?;
        Ok(())
    })])
    .unwrap();
    let report = Migrator::new(&mut kv, &registry, &info).migrate(2, 2_000, &mut ()).unwrap();
    assert_eq!(report.from, 1);
    assert_eq!(report.final_version, 2);
    assert_eq!((report.totals.added, report.totals.removed), (2, 2), "m/ -> msg/ renames two keys");

    assert_eq!(kv.get(b"msg/one").unwrap().as_deref(), Some(&b"1"[..]));
    assert_eq!(kv.get(b"m/one").unwrap(), None);
    // The reserved meta keys are inside the namespace (so they cannot forge another component's),
    // and the component view does not see them.
    assert!(store.keys().iter().any(|k| k == b"svc/__wa/meta/schema"));
    let mut view = wa_state::UserView::new(&mut kv);
    assert_eq!(view.get(b"__wa/meta/schema").unwrap(), None);
    assert!(view.put(b"__wa/meta/schema", b"99").is_err());
}

#[test]
fn a_store_failure_is_reported_not_swallowed() {
    /// A store whose writes fail: the queue must refuse the enqueue, not report success.
    struct Broken;
    impl Store for Broken {
        fn get(&self, _: &[u8]) -> Result<Option<Vec<u8>>, String> {
            Ok(None)
        }
        fn put(&self, _: &[u8], _: &[u8]) -> Result<(), String> {
            Err("disk on fire".into())
        }
        fn del(&self, _: &[u8]) -> Result<(), String> {
            Err("disk on fire".into())
        }
        fn delete_prefix(&self, _: &[u8]) -> Result<u64, String> {
            Err("disk on fire".into())
        }
        fn scan_page(&self, _: &[u8], _: Option<&[u8]>, _: usize) -> Result<Entries, String> {
            Err("disk on fire".into())
        }
    }

    use wa_queue::{EnqueueRequest, Policy, Queue};
    let queue = Queue::new(
        Arc::new(Namespaced::new(Arc::new(Broken), "svc/q/")),
        Arc::new(wa_queue::FixedClock::new(1)),
        Policy::default(),
    );
    let error = queue.enqueue(EnqueueRequest::new("wa.stt", b"x".to_vec())).unwrap_err();
    assert!(matches!(error, wa_queue::QueueError::Kv(_)), "{error}");
}
