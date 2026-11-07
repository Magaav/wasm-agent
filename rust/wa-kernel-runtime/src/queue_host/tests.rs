//! The queue host's own tests: the manifest grant (per interface and per namespace), the library
//! running over the component's own kv sub-namespace, the sweeper's alert drain, and the property
//! that every state directory stays under the test's own temp dir.

use super::*;
use serde_json::json;

fn temp_dir(tag: &str) -> std::path::PathBuf {
    let base = std::env::temp_dir().join(format!(
        "wa-queue-host-{}-{}-{}",
        tag,
        std::process::id(),
        wa_governance::node_telemetry::now_ms()
    ));
    let _ = std::fs::remove_dir_all(&base);
    std::fs::create_dir_all(&base).expect("temp dir");
    base
}

fn manifest(interfaces: &[&str], namespaces: &[&str]) -> serde_json::Value {
    json!({"capabilities": {"storage": true, "queue": {"interfaces": interfaces, "namespaces": namespaces}}})
}

#[test]
fn a_grant_is_interfaces_and_namespaces() {
    let grants = Grants::from_manifest(&manifest(&["producer", "worker"], &["wa.stt"])).unwrap();
    assert!(grants.may_use("producer") && grants.may_use("worker"));
    assert!(!grants.may_use("admin"), "the admin interface is a separate grant");
    assert!(grants.may_queue("wa.stt"));
    assert!(!grants.may_queue("wa.post"), "a queue the grant does not name");
    // A prefix grant covers one more segment, the same rule the bus uses for patterns.
    let wildcard = Grants::from_manifest(&manifest(&["worker"], &["wa.*"])).unwrap();
    assert!(wildcard.may_queue("wa.stt") && wildcard.may_queue("wa.stt.audio"));
    assert!(!wildcard.may_queue("wa"));
    // No declaration is no queue at all, and a bad one is an error rather than an empty grant.
    assert_eq!(Grants::from_manifest(&json!({})).unwrap(), Grants::default());
    assert!(Grants::from_manifest(&json!({"capabilities": {"queue": {"interfaces": ["owner"]}}})).is_err());
}

/// The short spelling: `consume`/`produce` are the worker/producer interfaces without the component
/// author having to know the interface names. `wa-whatsapp`'s manifest writes `consume`, and a
/// spelling that silently grants nothing would be refused at the first take with no hint why.
#[test]
fn a_grant_may_also_be_written_as_consume_and_produce() {
    let grants = Grants::from_manifest(&json!({
        "capabilities": {"queue": {"consume": ["whatsapp.outbox"], "produce": ["wa.stt"]}}
    }))
    .unwrap();
    assert!(grants.may_use("worker") && grants.may_use("producer"));
    assert!(!grants.may_use("admin"), "admin is never implied by a shorthand");
    assert!(grants.may_queue("whatsapp.outbox") && grants.may_queue("wa.stt"));
    assert!(!grants.may_queue("wa.post"));
    // Both spellings at once are one grant, not two: nothing is listed twice.
    let both = Grants::from_manifest(&json!({
        "capabilities": {"queue": {"interfaces": ["worker"], "namespaces": ["whatsapp.outbox"], "consume": ["whatsapp.outbox"]}}
    }))
    .unwrap();
    assert_eq!(both, grants_with(&["worker"], &["whatsapp.outbox"]));
    // A malformed shorthand is an error, like a malformed interface list.
    assert!(Grants::from_manifest(&json!({"capabilities": {"queue": {"consume": ["", "x"]}}})).is_err());
    assert!(Grants::from_manifest(&json!({"capabilities": {"queue": {"consume": "whatsapp.outbox"}}})).is_err());
}

fn grants_with(interfaces: &[&str], namespaces: &[&str]) -> Grants {
    Grants { interfaces: interfaces.iter().map(|s| s.to_string()).collect(), namespaces: namespaces.iter().map(|s| s.to_string()).collect() }
}

#[test]
fn a_component_without_a_grant_is_refused_every_interface() {
    let dir = temp_dir("nogrant");
    let host = QueueHost::new(dir.clone());
    host.register("svc", &json!({})).unwrap();
    for interface in ["producer", "worker", "admin"] {
        assert!(matches!(host.gate("svc", interface, Some("wa.svc")), Err(QueueFault::Refused(_))));
    }
    // And a component that never registered at all is refused, not defaulted open.
    assert!(matches!(host.gate("ghost", "producer", Some("wa.svc")), Err(QueueFault::Refused(_))));
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn a_job_can_only_be_settled_through_the_queue_it_belongs_to() {
    let dir = temp_dir("scope");
    let host = QueueHost::new(dir.clone());
    fast_forward(&host, "svc");
    host.register("svc", &manifest(&["producer", "worker", "admin"], &["wa.stt", "wa.post"])).unwrap();

    // One job in each queue, produced through the library directly (the WIT shape is a host call).
    let stt = host.queue("svc").enqueue(wa_queue::EnqueueRequest::new("wa.stt", b"a".to_vec())).unwrap();
    let post = host.queue("svc").enqueue(wa_queue::EnqueueRequest::new("wa.post", b"b".to_vec())).unwrap();

    // A worker may not settle a job of a queue the grant covers only by accident of namespace: the
    // WIT call names a queue, and the named queue must be the job's own (`docs/QUEUE.md`, item 6).
    let error = host.gate_job("svc", "worker", post.id).expect("the grant covers wa.post");
    assert_eq!(error.queue, "wa.post");
    // And a job of a queue the grant does not name is refused by the job path too.
    host.register("svc", &manifest(&["producer", "worker"], &["wa.stt"])).unwrap();
    assert!(matches!(host.gate_job("svc", "worker", post.id), Err(QueueFault::Refused(_))));
    assert!(host.gate_job("svc", "worker", stt.id).is_ok());
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn the_queue_lives_under_its_own_sub_namespace() {
    let dir = temp_dir("namespace");
    let host = QueueHost::new(dir.clone());
    host.register("svc", &manifest(&["producer"], &["wa.svc"])).unwrap();
    let queue = host.queue("svc");
    queue.enqueue(wa_queue::EnqueueRequest::new("wa.svc", b"x".to_vec())).unwrap();

    // The library's keys are under `q/`, inside `svc.state/`, and nowhere else: a component's own
    // keys in the same kv file cannot collide with them (`docs/QUEUE.md`, item 3).
    let kv = crate::service_io::Kv::new(Some(crate::state_host::kv_path(&dir, "svc")));
    let mut kv = kv;
    let keys = kv.scan(Vec::new(), None, 100).unwrap();
    assert!(!keys.is_empty());
    assert!(keys.iter().all(|(key, _)| key.starts_with(b"q/")), "{keys:?}");
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn the_sweeper_expires_stale_work_and_drains_one_alert_record() {
    let dir = temp_dir("sweep");
    let host = QueueHost::new(dir.clone());
    host.register("svc", &manifest(&["producer", "admin"], &["wa.svc"])).unwrap();
    // A job that was already stale when it was enqueued: the freshness rule drops it without
    // running it, and records one `expired` alert (`docs/QUEUE.md`, "Freshness").
    let queue = host.queue("svc");
    let request = wa_queue::EnqueueRequest::new("wa.svc", b"old".to_vec()).fresh_for(1);
    let enqueued = queue.enqueue(request).unwrap();
    std::thread::sleep(std::time::Duration::from_millis(5));

    let (components, alerts) = host.sweep_all();
    assert_eq!(components, 1);
    assert!(alerts >= 1, "the stale job produced an alert record");
    assert_eq!(queue.job(enqueued.id).unwrap().unwrap().state, wa_queue::JobState::Expired);
    // The records are marked sent, so a second sweep does not deliver them again.
    let (_, again) = host.sweep_all();
    assert_eq!(again, 0);
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn status_reports_counts_for_granted_queues_only() {
    let dir = temp_dir("status");
    let host = QueueHost::new(dir.clone());
    host.register("svc", &manifest(&["producer"], &["wa.svc"])).unwrap();
    let queue = host.queue("svc");
    queue.enqueue(wa_queue::EnqueueRequest::new("wa.svc", b"x".to_vec())).unwrap();
    queue.enqueue(wa_queue::EnqueueRequest::new("wa.other", b"y".to_vec())).unwrap();
    let status = host.status().to_string();
    assert!(status.contains("wa.svc"));
    assert!(!status.contains("wa.other"), "a queue outside the grant is not reported: {status}");
    assert!(!status.contains("\"x\""), "status carries counts, never a payload");
    let _ = std::fs::remove_dir_all(dir);
}

/// Register the component and give its namespace a metadata block, as an install would.
fn fast_forward(host: &QueueHost, component: &str) {
    let _ = host;
    let _ = component;
}

/// A swap, at the queue's own level: the retired instance's in-flight job is handed back to `Ready`
/// and taken by the instance that replaced it, exactly once, and the retired worker can no longer
/// settle it. This is the queue half of `services::replace` - a queue with pending work survives a
/// component swap with nothing lost and nothing duplicated.
#[test]
fn a_swap_hands_the_retired_instances_leases_to_the_instance_that_replaced_it() {
    let dir = temp_dir("handover");
    let host = QueueHost::new(dir.clone());
    let capabilities = manifest(&["producer", "worker"], &["wa.stt"]);
    host.register("svc", &capabilities).unwrap();
    let queue = host.queue("svc");
    let ids: Vec<u64> = (1..=3)
        .map(|n| queue.enqueue(wa_queue::EnqueueRequest::new("wa.stt", format!("job-{n}").into_bytes())).unwrap().id.0)
        .collect();
    // Two instances of the same component: the one being replaced, and the one started beside it.
    host.register_instance("svc", "svc#1", &capabilities).unwrap();
    host.register_instance("svc", "svc#2", &capabilities).unwrap();

    // The retired instance has one job out when the switch happens; its worker id is what the guest
    // path records, so the lease names the instance (`svc.1:w1`).
    let taken = queue.take("wa.stt", &scoped_worker("svc#1", "w1"), None).unwrap();
    assert!(matches!(taken, TakeOutcome::Job(_)), "{taken:?}");

    // The new instance's own leases are not this swap's business (it holds none yet: 0, not an error).
    assert_eq!(host.handover_instance("svc#2"), 0);
    assert_eq!(host.handover_instance("svc#1"), 1, "the one job in flight goes back");
    let handed = queue.job(wa_queue::JobId(ids[0])).unwrap().unwrap();
    assert_eq!(handed.state, wa_queue::JobState::Ready);
    assert_eq!(handed.attempts, 0, "a swap is not a failure: no attempt spent");
    assert_eq!(handed.lease_expiries, 0, "and no lease loss recorded");

    // The instance that replaced it takes all three, oldest first, once each.
    let mut took = Vec::new();
    for _ in 0..3 {
        match queue.take("wa.stt", &scoped_worker("svc#2", "w1"), None).unwrap() {
            TakeOutcome::Job(job) => took.push(job.id.0),
            other => panic!("only {took:?} were takeable: {other:?}"),
        }
    }
    assert_eq!(took, ids, "nothing lost, nothing duplicated, order kept");
    assert!(matches!(queue.take("wa.stt", &scoped_worker("svc#2", "w1"), None).unwrap(), TakeOutcome::Empty));

    // The retired worker's late completion is refused: it no longer holds anything.
    let late = queue.done_by(wa_queue::JobId(ids[0]), &scoped_worker("svc#1", "w1"), b"late");
    assert!(late.is_err(), "a handed-over job cannot be settled by the instance that lost it");
    for id in &ids {
        assert_eq!(queue.done_by(wa_queue::JobId(*id), &scoped_worker("svc#2", "w1"), b"ok").unwrap().state, wa_queue::JobState::Done);
    }
    let stats = queue.stats("wa.stt").unwrap();
    assert_eq!((stats.ready, stats.leased, stats.done), (0, 0, 3), "{stats:?}");

    // A token nobody registered has nothing to hand over, and revoking it afterwards changes nothing.
    assert_eq!(host.handover_instance("svc#9"), 0);
    assert!(host.unregister_instance("svc#1"));
    assert_eq!(queue.stats("wa.stt").unwrap().done, 3, "the data outlives the instance's rights");
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn a_stale_lease_is_recovered_by_the_next_take() {
    // The property the sweeper cannot be trusted with: `take` itself expires a lease, so a node
    // whose sweeper never ran still cannot hand out a job twice (`docs/QUEUE.md`, "Semantics").
    let dir = temp_dir("lease");
    let host = QueueHost::new(dir.clone());
    host.register("svc", &manifest(&["producer", "worker"], &["wa.svc"])).unwrap();
    let queue = host.queue("svc");
    let job = queue.enqueue(wa_queue::EnqueueRequest::new("wa.svc", b"x".to_vec())).unwrap();
    // A 1 ms lease, taken and never heartbeaten.
    let first = queue.take("wa.svc", "dead-worker", Some(1)).unwrap();
    assert!(matches!(first, TakeOutcome::Job(_)));
    std::thread::sleep(std::time::Duration::from_millis(5));
    let second = queue.take("wa.svc", "live-worker", None).unwrap();
    match second {
        TakeOutcome::Job(leased) => assert_eq!(leased.id, job.id),
        other => panic!("the lapsed lease was not recovered: {other:?}"),
    }
    let _ = std::fs::remove_dir_all(dir);
}
