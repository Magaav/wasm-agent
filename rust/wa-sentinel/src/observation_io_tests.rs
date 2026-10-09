//! Private sockets and explicit clock: deferred observation must perform no owner HTTP.
use super::*;
use std::io::{Read, Write};
use std::sync::{Arc, atomic::{AtomicBool, AtomicUsize, Ordering}};

#[test]
fn observation_io_is_due_guarded_and_failed_ownership_backs_off() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let home = std::env::temp_dir().join(format!("wa-observation-io-{}-{}", std::process::id(), now_epoch()));
    let previous = std::env::var_os("WASM_AGENT_HOME");
    let oldport = std::env::var_os("WASM_AGENT_PORT");
    let oldauth = std::env::var_os("WA_SENTINEL_AUTH_SESSION");
    let oldinstall=std::env::var_os("WA_INSTALL_DIR");
    std::fs::create_dir_all(home.join("install")).unwrap();
    std::env::set_var("WA_INSTALL_DIR",home.join("install"));
    std::env::set_var("WASM_AGENT_HOME", &home);
    std::env::set_var("WA_SENTINEL_AUTH_SESSION", "private-auth");
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    std::env::set_var("WASM_AGENT_PORT", listener.local_addr().unwrap().port().to_string());
    let stop = Arc::new(AtomicBool::new(false));
    let calls = Arc::new(AtomicUsize::new(0));
    let changed = Arc::new(AtomicBool::new(false));
    let valid = Arc::new(AtomicBool::new(false));
    let (stopped, count, foreign, exists) = (stop.clone(), calls.clone(), changed.clone(), valid.clone());
    let server = std::thread::spawn(move || {
        while !stopped.load(Ordering::SeqCst) {
            match listener.accept() {
                Ok((mut stream, _)) => {
                    stream.set_nonblocking(false).unwrap();
                    stream.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
                    let mut buf = [0; 4096];
                    let n = stream.read(&mut buf).unwrap();
                    let request = String::from_utf8_lossy(&buf[..n]);
                    count.fetch_add(1, Ordering::SeqCst);
                    assert!(request.starts_with("GET /session/owner?id=parent "), "transcript route forbidden: {request}");
                    assert!(request.to_ascii_lowercase().contains("x-wa-session: private-auth"));
                    let body = if foreign.load(Ordering::SeqCst) {
                        r#"{"session":{"id":"parent","user_id":"foreign"}}"#
                    } else if exists.load(Ordering::SeqCst) { r#"{"session":{"id":"parent","user_id":"owner"}}"# }
                    else { r#"{"error":"unknown_session"}"# };
                    write!(stream, "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
                }
                Err(_) => std::thread::sleep(Duration::from_millis(2)),
            }
        }
    });
    let now = now_epoch();
    let intent = json!({"id":"private-io","verb":"deploy","expected_sha":"a".repeat(40),"session":"parent","owner":"owner","queued_at":now});
    deploy_protocol::intake(&intent, "private-io").unwrap();
    let dir = sentinel_dir().join("deploy-protocol/private-io");
    // Legacy cursor must short-circuit even if no binding/owner can be obtained.
    wa_operation::atomic_json(&dir.join("observation.json"), &json!({"slot":1,"next_at":now+10})).unwrap();
    for _ in 0..50 { sentinel_return::observe_at("private-io", now).unwrap(); }
    assert_eq!(calls.load(Ordering::SeqCst), 0);
    wa_operation::atomic_json(&dir.join("observation.json"), &json!({"slot":1,"next_at":u64::MAX})).unwrap();
    sentinel_return::observe_at("private-io", now+100).unwrap();
    assert_eq!(calls.load(Ordering::SeqCst), 0, "consumed terminal cursor stays cheap");
    std::fs::remove_file(dir.join("observation.json")).unwrap();
    assert!(sentinel_return::observe_at("private-io", now).unwrap_err().to_string().contains("identity_not_confirmed"));
    for _ in 0..50 { sentinel_return::observe_at("private-io", now+9).unwrap(); }
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    assert!(sentinel_return::observe_at("private-io", now+10).is_err());
    sentinel_return::observe_at("private-io", now+29).unwrap();
    assert_eq!(calls.load(Ordering::SeqCst), 2);
    changed.store(true, Ordering::SeqCst);
    assert!(sentinel_return::observe_at("private-io", now+30).unwrap_err().to_string().contains("owner_mismatch"));
    sentinel_return::observe_at("private-io", now+69).unwrap();
    assert_eq!(calls.load(Ordering::SeqCst), 3);
    assert!(sentinel_return::observe_at("private-io", now+70).is_err());
    let schedule: Value = serde_json::from_slice(&std::fs::read(dir.join("observation-poll.json")).unwrap()).unwrap();
    assert_eq!(schedule["next_at"], now+130, "failure retry capped at sixty seconds");
    assert!(!dir.join("binding.json").exists());
    assert!(!dir.join("returns").exists(), "failed owner grants no return authority");
    assert!(!dir.join("effect.json").exists());
    valid.store(true, Ordering::SeqCst);
    changed.store(false, Ordering::SeqCst);
    let store=jobs::store();
    let definition:Value=serde_json::from_str(include_str!("../../../jobs/on-sentinel-return.json")).unwrap();
    store.put(&definition).unwrap();
    store.enable("onSentinelReturn",true).unwrap();
    sentinel_return::observe_at("private-io", now+130).unwrap();
    let journal=std::fs::read(dir.join("returns/private-io-0.json")).unwrap();
    let schedule:Value=serde_json::from_slice(&std::fs::read(dir.join("observation-poll.json")).unwrap()).unwrap();
    assert_eq!(schedule["failures"],0);
    assert_eq!(schedule["next_at"],now+140);
    for _ in 0..50 {sentinel_return::observe_at("private-io",now+139).unwrap();}
    assert_eq!(calls.load(Ordering::SeqCst),5,"successful pending observations also obey cadence");
    // A notification with unknown HTTP outcome cannot block independent install
    // observation or earn a replay. Keep the immutable pending slot unchanged.
    let cursor=std::fs::read(dir.join("pending-return.json")).unwrap();
    wa_operation::atomic_json(&dir.join("delivery-private-io-0.json"),&json!({"phase":"unknown"})).unwrap();
    wa_operation::atomic_json(&dir.join("state.json"),&json!({"id":"private-io","expected_sha":intent["expected_sha"],"at":now,"phase":"failed","detail":"separate installer failure"})).unwrap();
    sentinel_return::observe_at("private-io",now+140).unwrap();
    let observed:Value=serde_json::from_slice(&std::fs::read(dir.join("installation-observation.json")).unwrap()).unwrap();
    assert_eq!(observed["phase"],"failed");assert_eq!(observed["detail"],"separate installer failure");
    assert_eq!(std::fs::read(dir.join("returns/private-io-0.json")).unwrap(),journal);
    assert_eq!(std::fs::read(dir.join("pending-return.json")).unwrap(),cursor);
    // Older successful result is not the current installed generation. This must
    // refuse BEFORE launching Git/Node verification for a historical unknown.
    let mut result=json!({"ok":true,"request_id":"private-io","expected_sha":intent["expected_sha"],"at":"2026-01-01T00:00:00Z"});
    // Attribute the exact UTC timestamp to the test's actual queue clock.
    #[cfg(windows)] let time=quiet_command("powershell.exe").args(["-NoProfile","-NonInteractive","-Command",&format!("[DateTimeOffset]::FromUnixTimeSeconds({now}).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')")]).output().unwrap();
    #[cfg(not(windows))] let time=quiet_command("date").args(["-u","-d",&format!("@{now}"),"+%Y-%m-%dT%H:%M:%SZ"]).output().unwrap();
    result["at"]=json!(String::from_utf8(time.stdout).unwrap().trim());
    wa_operation::atomic_json(&dir.join("result.json"),&result).unwrap();
    wa_operation::atomic_json(&dir.join("state.json"),&json!({"id":"private-io","expected_sha":intent["expected_sha"],"at":now,"phase":"spawned"})).unwrap();
    std::fs::write(home.join("install/installed.txt"),format!("resolved_commit={}\n","b".repeat(40))).unwrap();
    sentinel_return::observe_at("private-io",now+150).unwrap();
    let observed:Value=serde_json::from_slice(&std::fs::read(dir.join("installation-observation.json")).unwrap()).unwrap();
    assert_eq!(observed["phase"],"failed");assert!(observed["detail"].as_str().unwrap().contains("generation_not_current"));
    assert!(!dir.join("verification.json").exists());
    let status:Value=serde_json::from_slice(&std::fs::read(dir.join("return-status.json")).unwrap()).unwrap();assert_eq!(status["phase"],"unknown");
    changed.store(true, Ordering::SeqCst);
    assert!(sentinel_return::observe_at("private-io",now+160).unwrap_err().to_string().contains("owner_mismatch"));
    assert_eq!(std::fs::read(dir.join("returns/private-io-0.json")).unwrap(),journal,"owner change cannot replace immutable return");
    assert!(!dir.join("effect.json").exists());
    std::fs::write(dir.join("observation-poll.json"),b"{").unwrap();
    assert!(sentinel_return::observe_at("private-io",now+170).unwrap_err().to_string().contains("schedule_corrupt"));
    assert_eq!(calls.load(Ordering::SeqCst),8,"corrupt schedule refuses before HTTP");
    stop.store(true, Ordering::SeqCst);
    server.join().unwrap();
    for (key, value) in [("WASM_AGENT_HOME", previous), ("WASM_AGENT_PORT", oldport), ("WA_SENTINEL_AUTH_SESSION", oldauth),("WA_INSTALL_DIR",oldinstall)] {
        match value { Some(v) => std::env::set_var(key,v), None => std::env::remove_var(key) }
    }
    eprintln!("private observation I/O evidence retained {}", home.display());
}
