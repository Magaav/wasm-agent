use super::*;
use std::sync::atomic::{AtomicUsize, Ordering};
static SEQ: AtomicUsize = AtomicUsize::new(0);
fn store() -> Store {
    Store::new(std::env::temp_dir().join(format!(
        "wa-jobs-test-{}-{}.db",
        std::process::id(),
        SEQ.fetch_add(1, Ordering::Relaxed)
    )))
}
fn definition() -> Value {
    json!({"id":"messages","name":"Message received","trigger":{"kind":"event","topic":"whatsapp.message"},"action":{"kind":"wake","session":"thread-id","prompt":"Apply the reviewed response policy.","skill":"reply-policy"}})
}
#[test]
fn history_does_not_force_queue_and_budget_table_scans() {
    let s = store();
    let db = s.db().unwrap();
    for (query, index) in [
        (
            "SELECT count(*) FROM deliveries WHERE state='queued'",
            "deliveries_queue",
        ),
        (
            "SELECT count(*) FROM deliveries WHERE job_id='x' AND state='running'",
            "deliveries_job_state",
        ),
        (
            "SELECT state FROM deliveries WHERE job_id='x' ORDER BY id DESC LIMIT 1",
            "deliveries_job_recent",
        ),
        (
            "SELECT count(*) FROM deliveries WHERE started_at>=1 AND action_kind='wake'",
            "deliveries_wake_budget",
        ),
    ] {
        let plan: String = db
            .query_row(&format!("EXPLAIN QUERY PLAN {query}"), [], |r| r.get(3))
            .unwrap();
        assert!(plan.contains(index), "{plan}");
    }
}

#[test]
fn default_off_and_revision_invalidates_pending() {
    let s = store();
    assert_eq!(s.put(&definition()).unwrap()["enabled"], false);
    assert_eq!(s.emit("whatsapp.message", "m1", &json!({}), 10).unwrap(), 0);
    let job = s.enable("messages", true).unwrap();
    assert_eq!(s.emit("whatsapp.message", "m1", &json!({}), 10).unwrap(), 1);
    assert_eq!(s.emit("whatsapp.message", "m1", &json!({}), 10).unwrap(), 0);
    s.enable("messages", false).unwrap();
    assert!(s.claim(11, 6).unwrap().is_none());
    assert!(!s
        .current("messages", job["revision"].as_i64().unwrap())
        .unwrap());
    assert_eq!(s.history().unwrap()[0]["state"], "cancelled");
}
#[test]
fn changed_instruction_requires_reapproval() {
    let s = store();
    s.put(&definition()).unwrap();
    s.enable("messages", true).unwrap();
    s.emit("whatsapp.message", "m1", &json!({}), 10).unwrap();
    let mut job = definition();
    job["action"]["prompt"] = json!("new instruction");
    assert_eq!(s.put(&job).unwrap()["enabled"], false);
    assert!(s.claim(11, 6).unwrap().is_none());
}

/// An import that says nothing new must change nothing: not the revision, not the enabled state, and not
/// the deliveries already waiting. Re-sending a byte-identical job used to bump the revision, which
/// cancels every queued delivery - so a re-deploy silently ate the events that had just arrived.
#[test]
fn identical_put_is_a_no_op_and_keeps_pending_deliveries() {
    let s = store();
    s.put(&definition()).unwrap();
    s.enable("messages", true).unwrap();
    let enabled = s.get("messages").unwrap();
    assert_eq!(s.emit("whatsapp.message", "m1", &json!({}), 10).unwrap(), 1);
    let again = s.put(&definition()).unwrap();
    // `enable` legitimately bumps the revision, so the no-op is measured against the state just before it.
    assert_eq!(again["revision"], enabled["revision"]);
    assert_eq!(again["enabled"], true);
    assert_eq!(again["queued"], 1);
    assert!(s.claim(11, 6).unwrap().is_some());
}

/// A delivery refused for budget has not had a side effect - nothing happened - so it goes back to the
/// queue instead of failing, and the refusal does not spend the allowance it was refused from.
#[test]
fn defer_requeues_without_spending_the_budget() {
    let s = store();
    s.put(&definition()).unwrap();
    s.enable("messages", true).unwrap();
    s.emit("whatsapp.message", "m1", &json!({}), 10).unwrap();
    let claimed = s.claim(11, 1).unwrap().unwrap();
    assert!(s.claim(11, 1).unwrap().is_none());
    s.defer(claimed["id"].as_i64().unwrap(), "wake budget reached")
        .unwrap();
    let again = s.claim(11, 1).unwrap();
    assert!(again.is_some(), "a deferred delivery must be claimable again");
    s.finish(again.unwrap()["id"].as_i64().unwrap(), "completed", "ok", 12)
        .unwrap();
}
#[test]
fn exclusive_claim_budget_and_unknown_recovery() {
    let s = store();
    s.put(&definition()).unwrap();
    s.enable("messages", true).unwrap();
    for n in 0..3 {
        s.emit("whatsapp.message", &format!("m{n}"), &json!({}), 10)
            .unwrap();
    }
    let first = s.claim(11, 1).unwrap().unwrap();
    assert!(s.claim(11, 1).unwrap().is_none());
    assert_eq!(s.recover(12).unwrap(), 1);
    assert_eq!(s.history().unwrap()[2]["state"], "unknown");
    assert!(s.claim(13, 1).unwrap().is_none());
    assert!(s.claim(4000, 1).unwrap().is_some());
    assert!(s
        .finish(
            first["id"].as_i64().unwrap(),
            "completed",
            "wrong late result",
            4000
        )
        .is_err());
}
#[test]
fn queue_is_bounded_and_not_silently_dropped() {
    let s = store();
    s.put(&definition()).unwrap();
    s.enable("messages", true).unwrap();
    for n in 0..8 {
        s.emit("whatsapp.message", &format!("m{n}"), &json!({}), 10)
            .unwrap();
    }
    assert!(s
        .emit("whatsapp.message", "overflow", &json!({}), 10)
        .is_err());
}
#[test]
fn schedules_prime_without_storm_and_persist() {
    let s = store();
    let mut job = definition();
    job["trigger"] = json!({"kind":"schedule","every_seconds":5});
    s.put(&job).unwrap();
    s.enable("messages", true).unwrap();
    assert_eq!(s.schedule(10).unwrap(), 0);
    assert_eq!(s.schedule(14).unwrap(), 0);
    assert_eq!(s.schedule(15).unwrap(), 1);
    let reopened = Store::new(&s.path);
    assert_eq!(reopened.schedule(15).unwrap(), 0);
    assert_eq!(reopened.schedule(500).unwrap(), 1);
}
#[test]
fn rejects_ambient_authority_and_invalid_inputs() {
    let s = store();
    let mut job = definition();
    job["action"] = json!({"kind":"shell","command":"echo bad"});
    assert!(s.put(&job).is_err());
    job["action"] = json!({"kind":"run","script":"relative.sh"});
    assert!(s.put(&job).is_err());
    job = definition();
    job["trigger"] = json!({"kind":"cdp","websocket_url":"ws://example.com/devtools/page/123","binding":"wa_event"});
    assert!(s.put(&job).is_err());
}
#[test]
fn deterministic_action_requires_no_wake_budget() {
    let s = store();
    let mut job = definition();
    job["action"] = json!({"kind":"run","script":std::env::temp_dir().join("reviewed.sh")});
    s.put(&job).unwrap();
    s.enable("messages", true).unwrap();
    s.emit("whatsapp.message", "m1", &json!({}), 10).unwrap();
    let d = s.claim(11, 0).unwrap().unwrap();
    assert_eq!(d["action"]["kind"], "run");
    s.finish(d["id"].as_i64().unwrap(), "completed", "verified", 12)
        .unwrap();
    assert_eq!(s.history().unwrap()[0]["state"], "completed");
}
#[test]
fn two_consumers_cannot_claim_one_delivery() {
    let s = store();
    s.put(&definition()).unwrap();
    s.enable("messages", true).unwrap();
    s.emit("whatsapp.message", "m1", &json!({}), 10).unwrap();
    let a = s.clone();
    let b = s.clone();
    let one = std::thread::spawn(move || a.claim(11, 6).unwrap());
    let two = std::thread::spawn(move || b.claim(11, 6).unwrap());
    assert_eq!(
        [one.join().unwrap(), two.join().unwrap()]
            .iter()
            .filter(|v| v.is_some())
            .count(),
        1
    );
}
