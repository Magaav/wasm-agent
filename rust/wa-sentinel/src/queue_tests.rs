//! The queue record is the answer to "I queued it - what happened?". These tests hold it to that: the
//! states are durable, an unchanged observation does not move the clock, and a failure is never overwritten
//! by a later "it is still queued" glance.
use super::*;

fn isolated_home(name: &str) -> PathBuf {
    let home = std::env::temp_dir().join(format!("wa-queue-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(&home).unwrap();
    std::env::set_var("WASM_AGENT_HOME", &home);
    home
}

#[test]
fn a_held_request_is_recorded_with_the_reason_it_waits() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let home = isolated_home("held");
    let id = "1792694523243949100-4836-00000000000000000001";
    let dir = sentinel_dir();
    std::fs::write(
        dir.join(format!("requests/{id}.json")),
        br#"{"verb":"restart","reason":"waiting test","queued_at":1000}"#,
    )
    .unwrap();
    let mut held = Held::default();
    announce_hold(&mut held, &format!("{id}.json"), "restart", "the node is busy", "waiting test");
    let record: Value = serde_json::from_slice(&std::fs::read(queue::dir().join(format!("{id}.json"))).unwrap()).unwrap();
    assert_eq!(record["state"], "waiting");
    assert_eq!(record["phase"], "held");
    assert_eq!(record["detail"], "the node is busy");
    assert_eq!(record["reason"], "waiting test");
    let first_at = record["updated_at"].as_u64().unwrap();

    // The same reason is not re-announced; the record stays where it is, so its age keeps meaning "waiting
    // since" rather than "last time the watcher ticked".
    announce_hold(&mut held, &format!("{id}.json"), "restart", "the node is busy", "waiting test");
    let again: Value = serde_json::from_slice(&std::fs::read(queue::dir().join(format!("{id}.json"))).unwrap()).unwrap();
    assert_eq!(again["updated_at"].as_u64().unwrap(), first_at);

    // A new reason is new information and replaces the detail.
    announce_hold(&mut held, &format!("{id}.json"), "restart", "the node's state cannot be proven", "waiting test");
    let changed: Value = serde_json::from_slice(&std::fs::read(queue::dir().join(format!("{id}.json"))).unwrap()).unwrap();
    assert_eq!(changed["detail"], "the node's state cannot be proven");

    std::env::remove_var("WASM_AGENT_HOME");
    let _ = std::fs::remove_dir_all(home);
}

#[test]
fn a_request_keeps_its_state_progress_and_failure() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let home = isolated_home("lifecycle");
    let request = json!({"verb":"restart","reason":"reload after install","queued_at":1_000});
    let id = "1792694523243949100-4836-00000000000000000000";

    queue::ensure_queued(&request, id);
    let first: Value = serde_json::from_slice(&std::fs::read(queue::dir().join(format!("{id}.json"))).unwrap()).unwrap();
    assert_eq!(first["state"], "queued");
    assert_eq!(first["verb"], "restart");
    assert_eq!(first["reason"], "reload after install");

    // Held says why it has not run; running says what it is doing now.
    queue::observe(&request, id, "waiting", "held", "the node is busy");
    let held: Value = serde_json::from_slice(&std::fs::read(queue::dir().join(format!("{id}.json"))).unwrap()).unwrap();
    assert_eq!(held["state"], "waiting");
    assert_eq!(held["phase"], "held");
    assert_eq!(held["detail"], "the node is busy");
    let held_at = held["updated_at"].as_u64().unwrap();

    let _performing = queue::begin_scope(&request, id);
    queue::step("stopping", "stopping node pid 4242");
    queue::step("verifying", "waiting for the node to answer /health");
    let running: Value = serde_json::from_slice(&std::fs::read(queue::dir().join(format!("{id}.json"))).unwrap()).unwrap();
    assert_eq!(running["state"], "running");
    assert_eq!(running["phase"], "verifying");
    assert_eq!(running["attempts"], 1);
    assert!(running["updated_at"].as_u64().unwrap() >= held_at);

    // An unchanged observation is not news and must not keep moving the timestamp: "stuck for 20 minutes"
    // has to stay true while the watcher ticks.
    let before = running["updated_at"].as_u64().unwrap();
    queue::observe(&request, id, "running", "verifying", "waiting for the node to answer /health");
    let again: Value = serde_json::from_slice(&std::fs::read(queue::dir().join(format!("{id}.json"))).unwrap()).unwrap();
    assert_eq!(again["updated_at"].as_u64().unwrap(), before);

    // Failure is the state an operator must be able to find later, and a stale glance must not erase it.
    queue::observe(&request, id, "failed", "failed", "the node on port 8799 did not answer /sync/head");
    queue::ensure_queued(&request, id);
    let failed: Value = serde_json::from_slice(&std::fs::read(queue::dir().join(format!("{id}.json"))).unwrap()).unwrap();
    assert_eq!(failed["state"], "failed");
    assert_eq!(failed["detail"], "the node on port 8799 did not answer /sync/head");

    // `status` reads the same record: a failed row carries verb, id and detail.
    let lines = queue::lines(now_epoch(), 8);
    assert_eq!(lines.len(), 1, "one observed request, one row: {lines:?}");
    assert!(lines[0].contains("failed") && lines[0].contains("restart") && lines[0].contains("/sync/head"), "{lines:?}");

    std::env::remove_var("WASM_AGENT_HOME");
    let _ = std::fs::remove_dir_all(home);
}
