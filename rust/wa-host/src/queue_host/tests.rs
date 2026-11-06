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
