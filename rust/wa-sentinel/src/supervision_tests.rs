//! Supervision: the node log a start leaves, a start that fails early, a wake that waits for its node, and
//! the autostart backoff.
use super::*;

#[test]
fn a_wake_waits_for_its_node_until_the_limit_then_fails() {
    // Queued at 1000, limit 1800s: kept and retried WAKE_RETRY_SECS later while younger than the limit.
    assert_eq!(wake_wait_retry(1000, 1000, 1800), Some(1000 + WAKE_RETRY_SECS));
    assert_eq!(wake_wait_retry(1000, 2799, 1800), Some(2799 + WAKE_RETRY_SECS));
    assert_eq!(wake_wait_retry(1000, 2800, 1800), None, "at the limit it is no longer kept");
    assert_eq!(wake_wait_retry(1000, 9000, 1800), None);
    // A queued_at in the future (clock skew) is young, not expired.
    assert_eq!(wake_wait_retry(5000, 1000, 1800), Some(1000 + WAKE_RETRY_SECS));
}

#[test]
fn autostart_backs_off_exponentially_to_five_minutes() {
    let schedule: Vec<u64> = (0..8).map(autostart_backoff).collect();
    assert_eq!(schedule, vec![0, 15, 30, 60, 120, 240, 300, 300]);
    assert_eq!(autostart_backoff(u32::MAX), 300, "never overflows");
}

#[test]
fn the_log_tail_is_the_last_non_empty_lines_in_order() {
    let text = "first\n\n  second  \nthird\n\n\nfourth\nfifth\nsixth\n\n";
    assert_eq!(log_tail(text, 5), vec!["second", "third", "fourth", "fifth", "sixth"]);
    assert_eq!(log_tail(text, 2), vec!["fifth", "sixth"]);
    assert!(log_tail("\n \n", 5).is_empty());
    assert_eq!(log_tail(&"x".repeat(1000), 1)[0].len(), 240, "a long line is clipped");
}

#[test]
fn a_listener_is_found_in_the_proc_table() {
    let table = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n\
   0: 0100007F:225F 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 4242 1 0 100 0 0 10 0\n\
   1: 0100007F:2260 0100007F:9C40 01 00000000:00000000 00:00000000 00000000  1000        0 4343 1 0 100 0 0 10 0\n";
    assert_eq!(listen_inode(table, 8799).as_deref(), Some("4242"));
    assert_eq!(listen_inode(table, 8800), None, "an established connection is not a listener");
    assert_eq!(listen_inode(table, 1), None);
}

#[cfg(unix)]
#[test]
fn a_node_that_exits_at_once_fails_the_start_early_with_its_log() {
    use std::os::unix::fs::PermissionsExt;
    let _lock = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let home = std::env::temp_dir().join(format!("wa-sentinel-supervision-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(&home).unwrap();
    let binary = home.join("wa");
    std::fs::write(&binary, "#!/bin/sh\nif [ \"$1\" = node ]; then echo '{\"node_id\":\"test-node\"}'; exit 0; fi\n\
echo 'binding_transport_already_owned' >&2\nsleep 1\nexit 2\n").unwrap();
    std::fs::set_permissions(&binary, std::fs::Permissions::from_mode(0o755)).unwrap();
    let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let saved: Vec<(&str, Option<String>)> = ["WASM_AGENT_HOME", "WASM_AGENT_PORT", "WA_SENTINEL_START_WAIT"]
        .iter().map(|key| (*key, std::env::var(key).ok())).collect();
    unsafe {
        std::env::set_var("WASM_AGENT_HOME", &home);
        std::env::set_var("WASM_AGENT_PORT", port.to_string());
        std::env::set_var("WA_SENTINEL_START_WAIT", "30");
    }
    let started = Instant::now();
    let outcome = start_and_verify(&binary, "test");
    for (key, value) in saved {
        unsafe { match value { Some(value) => std::env::set_var(key, value), None => std::env::remove_var(key) } }
    }
    let error = outcome.expect_err("a node that exits cannot be reported up").to_string();
    assert!(started.elapsed() < Duration::from_secs(15), "reported when it exited, not at the deadline: {error}");
    assert!(error.contains("exited with code 2"), "{error}");
    assert!(error.contains("binding_transport_already_owned"), "the log tail names the cause: {error}");
    let log = std::fs::read_to_string(home.join(".wasm-agent/serve.log")).unwrap();
    assert!(log.contains("sentinel start:") && log.contains("(test)"), "the header says who started it and why: {log}");
    let _ = std::fs::remove_dir_all(&home);
}
