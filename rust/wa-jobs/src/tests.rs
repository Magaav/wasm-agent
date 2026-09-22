use super::*;
use std::sync::atomic::{AtomicUsize, Ordering};
static SEQ: AtomicUsize = AtomicUsize::new(0);
/// A fresh store per test, in a path no other invocation can collide with.
///
/// The name used to be `(process id, per-process seq)` and the file was never removed. Process ids are
/// reused, so a later run could open an *old* database - and then `put` of an identical definition is the
/// documented no-op, leaving a job enabled that the test had just created and expected to be default-off.
/// That failed the whole gate intermittently, which is worse than failing it honestly. A per-call
/// timestamp makes the path unique across runs, not just across processes.
fn store() -> Store {
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_nanos())
        .unwrap_or(0);
    Store::new(std::env::temp_dir().join(format!(
        "wa-jobs-test-{}-{stamp}-{}.db",
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
fn a_full_queue_is_backpressure_for_a_scheduled_tick() {
    // A scheduled tick is this store's own event, so a full queue skips one interval instead of
    // failing: the deliveries already queued have not been consumed. Failing the whole tick logged
    // `jobs-error tick job_queue_full` every second and retried forever.
    let s = store();
    let mut job = definition();
    job["trigger"] = json!({"kind":"schedule","every_seconds":5});
    s.put(&job).unwrap();
    s.enable("messages", true).unwrap();
    assert_eq!(s.schedule(10).unwrap(), 0); // primes: next_at = 15
    // A schedule job has no event topic, so fill its queue directly: the per-job limit is 8.
    let rev = s.get("messages").unwrap()["revision"].as_i64().unwrap();
    for n in 0..8 {
        s.enqueue("messages", rev, &format!("e{n}"), &json!({}), 10)
            .unwrap();
    }
    // The tick cannot fit its delivery. It must not error, must say why, and must advance so the
    // retry is the next interval, not the next tick.
    assert_eq!(s.schedule(15).unwrap(), 0);
    let (status, next): (String, i64) = s
        .db()
        .unwrap()
        .query_row(
            "SELECT source_status, next_at FROM jobs WHERE id='messages'",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert!(status.contains("backpressure"), "expected backpressure, got {status}");
    assert_eq!(next, 20, "the tick must advance to the next interval, not retry each tick");
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

/// The two lanes are explicit. A deterministic `run` is claimed even when the inference lane is closed,
/// and an inference `wake` is never claimed on the deterministic pass - so a person's interactive turn
/// cannot stall the inbox ingest, and the ingest cannot spend a wake allowance.
#[test]
fn deterministic_and_inference_lanes_are_separate() {
    let s = store();
    let mut run_job = definition();
    run_job["id"] = json!("ingest");
    run_job["action"] = json!({"kind":"run","script":std::env::temp_dir().join("ingest.sh")});
    s.put(&run_job).unwrap();
    s.enable("ingest", true).unwrap();
    s.emit("whatsapp.message", "s1", &json!({}), 10).unwrap();

    let deterministic = s.claim_next(11, 0, false).unwrap().unwrap();
    assert_eq!(deterministic["action"]["kind"], "run");
    assert_eq!(deterministic["event_id"], "s1", "idempotency key needs the stable source id");
    s.finish(deterministic["id"].as_i64().unwrap(), "completed", "ok", 11)
        .unwrap();
    s.enable("ingest", false).unwrap();

    s.put(&definition()).unwrap();
    s.enable("messages", true).unwrap();
    s.emit("whatsapp.message", "m1", &json!({}), 10).unwrap();
    assert!(
        s.claim_next(11, 6, false).unwrap().is_none(),
        "a wake must not be claimed on the deterministic lane"
    );
    let wake = s.claim_next(11, 6, true).unwrap().unwrap();
    assert_eq!(wake["action"]["kind"], "wake");
    assert_eq!(wake["event_id"], "m1");
}

/// A subagent action is the profile-scoped route: it is valid JSON, it carries a profile, and it is an
/// inference action (so it never rides the deterministic lane).
#[test]
fn subagent_action_validates_and_is_inference() {
    let s = store();
    let job = json!({"id":"respond","name":"Respond as operator",
        "trigger":{"kind":"event","topic":"whatsapp.message"},
        "action":{"kind":"subagent","profile":"whatsapp-responder","prompt":"Decide; never send without approval.","timeout_seconds":900}});
    s.put(&job).unwrap();
    s.enable("respond", true).unwrap();
    s.emit("whatsapp.message", "m1", &json!({}), 10).unwrap();
    assert!(s.claim_next(11, 6, false).unwrap().is_none());
    let claimed = s.claim_next(11, 6, true).unwrap().unwrap();
    assert_eq!(claimed["action"]["profile"], "whatsapp-responder");
    let mut bad = job;
    bad["action"] = json!({"kind":"subagent","prompt":"no profile"});
    assert_eq!(s.put(&bad).unwrap_err().to_string(), "subagent_needs_profile");
}

/// Artifact round trip through the store: installs disabled, an identical import is a revision no-op,
/// and a changed artifact invalidates approval exactly like any other edit.
#[test]
fn artifact_import_installs_disabled_and_is_revision_safe() {
    let s = store();
    let job = json!({"id":"documents","name":"Validate incoming",
        "trigger":{"kind":"file","path":std::env::temp_dir().join("approved/incoming"),"pattern":".json"},
        "action":{"kind":"run","script":std::env::temp_dir().join("approved/procedures/validate.sh"),"timeout_seconds":60}});
    s.put(&job).unwrap();
    let artifact = s.export_job("documents").unwrap();
    assert!(artifact["trigger"].get("path").is_none());

    let bindings = json!({"trigger_path":std::env::temp_dir().join("approved/incoming"),
        "script":std::env::temp_dir().join("approved/procedures/validate.sh")});
    let imported = s.put_artifact(&artifact, &bindings, true, "operator").unwrap();
    assert_eq!(imported["job"]["enabled"], false, "an import is always disabled");
    let revision = imported["job"]["revision"].as_i64().unwrap();
    let again = s.put_artifact(&artifact, &bindings, true, "operator").unwrap();
    assert_eq!(again["job"]["revision"].as_i64().unwrap(), revision, "an identical import is a no-op");
    assert_eq!(again["job"]["enabled"], false);
    let mut edited = artifact.clone();
    edited["action"]["timeout_seconds"] = json!(120);
    let changed = s.put_artifact(&edited, &bindings, true, "operator").unwrap();
    assert!(changed["job"]["revision"].as_i64().unwrap() > revision, "an edit bumps the revision");
    assert_eq!(changed["job"]["enabled"], false);
}

/// A pipeline is a chain in one delivery: deterministic steps and the inference step that needs a model.
/// Two properties are load-bearing and asserted here - that its steps are validated with the same rules
/// the action level uses, and that a pipeline containing a child is classified as *inference*, so it can
/// never be claimed on the lane that runs beside a person's turn.
#[test]
fn a_pipeline_validates_its_steps_and_lands_on_the_inference_lane() {
    // A script path must be absolute *on this platform* - the rule the `run` action already enforces.
    // `/tmp/x.sh` is not an absolute path on Windows, which is how this test first failed.
    let dir = std::env::temp_dir();
    let read = dir.join("pipeline-read.sh").to_string_lossy().to_string();
    let report = dir.join("pipeline-report.sh").to_string_lossy().to_string();

    let good = json!({
        "id": "p", "name": "p",
        "trigger": {"kind": "schedule", "every_seconds": 60},
        "action": {"kind": "pipeline", "steps": [
            {"kind": "run", "script": read, "returns": "events"},
            {"kind": "foreach", "from": "events", "key": "message_id", "max": 8,
             "step": {"kind": "subagent", "profile": "whatsapp-responder", "prompt": "decide"}},
            {"kind": "run", "script": report}
        ]}
    });
    assert!(validate(&good).is_ok(), "run/foreach/run must validate: {:?}", validate(&good).err());
    assert!(action_is_inference(&good["action"]), "a pipeline that starts a child is inference");

    let deterministic = json!({"kind": "pipeline", "steps": [{"kind": "run", "script": read}]});
    assert!(!action_is_inference(&deterministic), "a pipeline of only run steps is deterministic");
    assert!(!action_is_inference(&json!({"kind": "run", "script": read})));
    assert!(action_is_inference(&json!({"kind": "subagent", "profile": "x", "prompt": "y"})));

    let refusal = |action: Value| {
        validate(&json!({"id": "p", "name": "p",
            "trigger": {"kind": "schedule", "every_seconds": 60}, "action": action}))
            .unwrap_err()
            .to_string()
    };
    assert_eq!(refusal(json!({"kind": "pipeline", "steps": []})), "pipeline_needs_steps");
    assert_eq!(
        refusal(json!({"kind": "pipeline", "steps": [{"kind": "run", "script": "relative.sh"}]})),
        "step_1_run_needs_absolute_script"
    );
    assert_eq!(
        refusal(json!({"kind": "pipeline", "steps": [{"kind": "run", "script": read, "returns": "not a name"}]})),
        "step_1_returns_must_be_a_name"
    );
    assert_eq!(
        refusal(json!({"kind": "pipeline", "steps": [{"kind": "foreach", "from": "e", "key": "k", "max": 0,
            "step": {"kind": "subagent", "profile": "x", "prompt": "y"}}]})),
        "step_1_foreach_max_out_of_range"
    );
    assert_eq!(
        refusal(json!({"kind": "pipeline", "steps": [{"kind": "foreach", "from": "e", "key": "k", "max": 2,
            "step": {"kind": "run", "script": read}}]})),
        "step_1_foreach_step_must_be_a_subagent"
    );
    assert_eq!(
        refusal(json!({"kind": "pipeline", "steps": [{"kind": "wake", "session": "s", "prompt": "p"}]})),
        "step_1_wake_not_allowed_in_pipeline"
    );
    assert_eq!(
        refusal(json!({"kind": "pipeline", "steps": [{"kind": "assert"}]})),
        "step_1_unknown_kind"
    );
}
