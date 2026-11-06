//! The fixture, through the fake kernel: the same `.wasm` a node would run, against scripted
//! answers. Every test here is one claim about the host half of `wa:kernel@0.2`.

use crate::{FakeKernel, HttpRule, SttScript, WsRule};
use std::sync::Arc;
use std::time::{Duration, Instant};

/// The component: built on demand for `wasm32-wasip2` (or taken from `WA_FAKE_KERNEL_FIXTURE`),
/// because a test that proves nothing about the real artifact is not worth running.
fn wasm() -> std::path::PathBuf {
    match crate::fixture_wasm() {
        Ok(path) => path,
        Err(error) => panic!("the fixture component must be buildable: {error}"),
    }
}

fn temp_dir(name: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("wa-fake-kernel-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("temp dir");
    dir
}

/// The config every end-to-end test uses: one granted exchange, one refused one, a socket, a
/// recognition, a secret, and a short life so the test does not depend on a stop signal.
fn config(exit_after_ms: u64) -> String {
    serde_json::json!({
        "dial": "http://127.0.0.1:9999/note",
        "refused": "http://127.0.0.2:9/note",
        "ws": "ws://127.0.0.1:9998/ws",
        "speech": true,
        "secret": "DEV_TOKEN",
        "exit_after_ms": exit_after_ms,
        "tick_ms": 20,
        "version": "test",
    })
    .to_string()
}

/// Everything the fixture can do, answered from memory: the run must complete, report ready, and
/// show each capability in its log with the answer the kernel scripted.
#[test]
fn the_fixture_runs_against_scripted_answers() {
    let mut kernel = FakeKernel::new("fake-kernel-fixture");
    kernel
        .grant_net(&["127.0.0.1:9999", "127.0.0.1:9998"])
        .grant_storage(true)
        .grant_stt(true)
        .secret("DEV_TOKEN", "s3cr3t-value")
        .http_response(HttpRule::ok_json("GET", "http://127.0.0.1:9999/note", r#"{"ok":true}"#))
        .websocket(WsRule::new("ws://127.0.0.1:9998/ws").delivering(&[b"pong"]).echoing())
        .speech(
            SttScript::text("bom dia")
                .language("pt")
                .elapsed_ms(7)
                .segment(0, 500, "bom dia"),
        );
    let outcome = kernel.run_file(wasm(), &config(300));
    let logs = outcome.logs_text();
    assert_eq!(outcome.outcome, "exit_0", "{logs}\nstderr: {}", outcome.stderr);
    assert!(logs.contains("start version=test"), "{logs}");
    assert!(logs.contains("kv ok value=1 page=1 deleted=0"), "the kv round trip ran: {logs}");
    assert!(logs.contains("secret ok 12 bytes"), "the granted secret was readable: {logs}");
    assert!(logs.contains("dial ok status=200 bytes=11"), "the scripted exchange completed: {logs}");
    assert!(logs.contains(r#"body={"ok":true}"#), "the body arrived over the stream: {logs}");
    assert!(logs.contains("refused (grant)"), "the ungranted address was refused by the kernel: {logs}");
    assert!(logs.contains("ws ok 4 bytes"), "the echoed frame arrived over the stream: {logs}");
    assert!(logs.contains("stt ok segments=1 first=bom dia"), "the segment stream ran: {logs}");
    assert!(logs.contains("result=7 chars language=pt"), "the transcript resolved once: {logs}");
    assert_eq!(outcome.health, "ready");
    assert!(outcome.stdout.contains("ready"), "the guest's own stdout is captured: {}", outcome.stdout);
    assert!(outcome.logs.iter().any(|line| line.target == "fake-kernel-fixture" && line.level == "info"));
    // The calls are in the order the component made them, which is what a replay matches on.
    let called = outcome.called();
    for expected in ["wa:kernel/kv.set", "wa:kernel/kv.get", "wa:kernel/http.send", "wa:kernel/websocket.connect", "wa:kernel/speech.recognize"] {
        assert!(called.iter().any(|call| call == expected), "{expected} missing from {called:?}");
    }
    // The value the component wrote is gone (it deleted its own key) and the write happened.
    assert_eq!(outcome.kv.get(b"fixture/counter".as_slice()), None);
}

/// A call no rule names is refused with its own reason, never answered with an empty success: a test
/// that forgets a script fails on the log line it expected.
#[test]
fn an_unscripted_exchange_is_refused_by_name() {
    let mut kernel = FakeKernel::new("fake-kernel-fixture");
    // Granted and reachable, but not scripted: the difference between "the network refused" and
    // "the test forgot" must be visible.
    kernel.grant_net(&["127.0.0.1:9999"]).grant_storage(true);
    let config = serde_json::json!({"dial": "http://127.0.0.1:9999/note", "exit_after_ms": 100}).to_string();
    let outcome = kernel.run_file(wasm(), &config);
    let logs = outcome.logs_text();
    assert!(!logs.contains("dial ok"), "an unscripted exchange must not answer ok: {logs}");
    assert!(logs.contains("http_not_scripted:GET http://127.0.0.1:9999/note"), "{logs}");
}

/// Without the `storage` grant the component's own namespace is refused - the fake kernel is a
/// kernel, not a convenience.
#[test]
fn an_ungranted_namespace_is_refused() {
    let mut kernel = FakeKernel::new("fake-kernel-fixture");
    kernel.grant_storage(false);
    let outcome = kernel.run_file(wasm(), &serde_json::json!({"exit_after_ms": 100}).to_string());
    assert!(outcome.logs_text().contains("kv unavailable Error::Refused(\"storage not declared\")"), "{}", outcome.logs_text());
    assert!(outcome.kv.is_empty());
}

/// Without the `stt` grant the recognizer is refused, and no script is consulted.
#[test]
fn an_ungranted_recognizer_is_refused() {
    let mut kernel = FakeKernel::new("fake-kernel-fixture");
    kernel.grant_stt(false).speech(SttScript::text("never"));
    let outcome = kernel.run_file(wasm(), &serde_json::json!({"speech": true, "exit_after_ms": 100}).to_string());
    assert!(outcome.logs_text().contains("stt failed Error::Refused(\"stt not declared\")"), "{}", outcome.logs_text());
}

/// A component that never returns is stopped by the run's deadline, and the outcome says so instead
/// of hanging the test.
#[test]
fn the_deadline_ends_a_component_that_never_returns() {
    let mut kernel = FakeKernel::new("fake-kernel-fixture");
    kernel.grant_storage(true).deadline(Duration::from_millis(5000)); // a cold compile under a busy build machine took >700 ms before the first tick
    let began = Instant::now();
    let outcome = kernel.run_file(wasm(), &serde_json::json!({"tick_ms": 10}).to_string());
    assert_eq!(outcome.outcome, "deadline", "{}", outcome.logs_text());
    assert!(began.elapsed() < Duration::from_secs(20), "the deadline must cut the run short: {:?}", began.elapsed());
    assert!(outcome.logs_text().contains("heartbeat"), "it did run before the deadline");
}

/// `lifecycle.stopping()` is the supervisor's own question: a component that asks it returns
/// cleanly, and the fake kernel's `Stopper` is that signal.
#[test]
fn a_stop_request_ends_the_run_cleanly() {
    let mut kernel = FakeKernel::new("fake-kernel-fixture");
    kernel.grant_storage(true).deadline(Duration::from_secs(30));
    let stopper = Arc::new(kernel.stopper());
    let signal = stopper.clone();
    let thread = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(400));
        signal.stop();
    });
    let outcome = kernel.run_file(wasm(), &serde_json::json!({"tick_ms": 10}).to_string());
    thread.join().unwrap();
    assert_eq!(outcome.outcome, "exit_0", "{}", outcome.logs_text());
    assert!(outcome.logs_text().contains("stopping cleanly"), "{}", outcome.logs_text());
    assert!(stopper.stop_requested());
}

/// The point of the hooks: a recorded run can be replayed with no scripts at all, and the guest sees
/// the same answers. What the file holds is what the second kernel answers.
#[test]
fn a_recorded_run_replays_without_scripts() {
    let mut recording = FakeKernel::new("fake-kernel-fixture");
    recording
        .grant_net(&["127.0.0.1:9999", "127.0.0.1:9998"])
        .grant_storage(true)
        .grant_stt(true)
        .secret("DEV_TOKEN", "s3cr3t-value")
        .http_response(HttpRule::ok_json("GET", "http://127.0.0.1:9999/note", r#"{"ok":true}"#))
        .websocket(WsRule::new("ws://127.0.0.1:9998/ws").delivering(&[b"pong"]).echoing())
        .speech(SttScript::text("bom dia").segment(0, 500, "bom dia"))
        .record();
    let first = recording.run_file(wasm(), &config(200));
    assert_eq!(first.outcome, "exit_0", "{}", first.logs_text());
    assert!(first.records > 5, "the ring recorded the calls: {}", first.records);
    let dir = temp_dir("replay");
    let saved = recording
        .kernel
        .lock()
        .unwrap()
        .journal
        .save(&dir, "fixture")
        .expect("a recorded run saves");
    assert!(saved.is_file(), "{}", saved.display());

    // Nothing scripted, nothing granted-as-data, no secret: only the replay.
    let mut replaying = FakeKernel::new("fake-kernel-fixture");
    replaying.grant_net(&["127.0.0.1:9999", "127.0.0.1:9998"]).grant_storage(true).grant_stt(true);
    replaying.replay_from(&saved).expect("the replay loads");
    let second = replaying.run_file(wasm(), &config(200));
    assert_eq!(second.replay_mismatch, None, "the replay must match the recorded calls");
    let logs = second.logs_text();
    assert!(logs.contains("kv ok value=1 page=1 deleted=0"), "{logs}");
    assert!(logs.contains("dial ok status=200 bytes=11"), "the recorded exchange was fed back: {logs}");
    assert!(logs.contains("ws ok 4 bytes"), "the recorded frames were fed back: {logs}");
    assert!(logs.contains("stt ok segments=1 first=bom dia"), "the recorded recognition was fed back: {logs}");
    // A secret's value is never in the file: the replay answers with the stand-in.
    assert!(logs.contains("secret ok 15 bytes"), "the stand-in 'replayed-secret' is 15 bytes: {logs}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A replay that drifts is reported by name, and the guest is told its call failed - answering a
/// question nobody asked would be worse than an error.
#[test]
fn a_replay_that_drifts_is_named() {
    let mut recording = FakeKernel::new("fake-kernel-fixture");
    recording.grant_storage(true).record();
    let first = recording.run_file(wasm(), &serde_json::json!({"dial": "http://127.0.0.1:9999/a", "exit_after_ms": 100}).to_string());
    assert_eq!(first.outcome, "exit_0");
    let dir = temp_dir("drift");
    let saved = recording.kernel.lock().unwrap().journal.save(&dir, "drift").expect("saves");

    let mut replaying = FakeKernel::new("fake-kernel-fixture");
    replaying.grant_net(&["127.0.0.1:9999"]).grant_storage(true);
    replaying.replay_from(&saved).expect("loads");
    // The same component, a different question: the recorded steps do not line up.
    let second = replaying.run_file(wasm(), &serde_json::json!({"speech": true, "exit_after_ms": 100}).to_string());
    let mismatch = second.replay_mismatch.clone().unwrap_or_default();
    assert!(mismatch.starts_with("replay_mismatch:") || mismatch.starts_with("replay_arguments_differ:"), "{mismatch}");
    assert!(second.logs_text().contains("stt failed"), "the drifted call failed visibly: {}", second.logs_text());
    let _ = std::fs::remove_dir_all(&dir);
}

/// A secret's value is never written into a record: the step carries the name and whether it was
/// granted, nothing more.
#[test]
fn a_secret_value_never_enters_a_record() {
    let mut kernel = FakeKernel::new("fake-kernel-fixture");
    kernel.grant_storage(true).secret("DEV_TOKEN", "s3cr3t-value").record();
    let outcome = kernel.run_file(wasm(), &serde_json::json!({"secret": "DEV_TOKEN", "exit_after_ms": 100}).to_string());
    assert_eq!(outcome.outcome, "exit_0");
    let dir = temp_dir("secret");
    let saved = kernel.kernel.lock().unwrap().journal.save(&dir, "secret").expect("saves");
    let replay = wa_bounded::Replay::load(&saved).expect("reads back");
    for record in &replay.records {
        for payload in [&record.args, &record.result] {
            if let Some(bytes) = payload.inline_bytes() {
                let text = String::from_utf8_lossy(bytes);
                assert!(!text.contains("s3cr3t-value"), "a secret leaked into {}:{}", record.interface, record.function);
            }
        }
    }
    let credentials = replay.records.iter().find(|record| record.function == "get" && record.interface.contains("credentials"));
    let recorded = credentials.expect("the credentials call was recorded");
    assert!(String::from_utf8_lossy(recorded.result.inline_bytes().unwrap_or_default()).contains("present"));
    let _ = std::fs::remove_dir_all(&dir);
}
