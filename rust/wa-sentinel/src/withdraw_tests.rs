//! `request withdraw <id>`: the request an operator can take back out of the queue.
//!
//! The concern: a request that is held - a deploy waiting for the node to go idle - never fails and never
//! runs until the node is idle, and `wa-sentinel status` said only "held: node busy". The operator had no
//! verb for "I no longer want that", so the only way to drop it was to stop the sentinel. Meanwhile a verb
//! that moved requests around without refusing the claimed ones would be worse than the gap: a request in
//! flight may have an effect half done, and a supervisor that abandons one is the failure this process exists
//! to prevent.
//!
//! What is proved here, with a scratch home and no live node:
//!
//!   1. a queued request is withdrawn: it leaves `requests/` for `withdrawn/` (kept, not deleted), the queue
//!      record says so, and exactly one audit line is written;
//!   2. a claimed request is refused by name and nothing moves - not the file, not the operation;
//!   3. `status` names the id of a held request and both things that can be done about it, and reading that
//!      line claims nothing;
//!   4. a request that is already done, failed or withdrawn is refused by the lane it is in, and an id that
//!      names nothing is refused as such;
//!   5. a withdrawn deploy settles its own outcome record, so the session is told it was withdrawn instead of
//!      the watchdog reporting the deploy silent an hour later;
//!   6. a withdrawn *protocol* deploy (one carrying --expected-sha, which its own return engine reports and the
//!      legacy outcome record never does) reaches the engine instead of leaving the session waiting for ever: the
//!      withdrawal is recorded as its state phase, and the observation lane turns it into the one terminal event.
//!
//! Falsification, each run by hand:
//!
//!   * copy the request into `withdrawn/` instead of renaming it - `a_queued_request_is_withdrawn_once_with_one_audit_line`
//!     fails on the file still being in the box, claimable by the next tick;
//!   * drop the claimed-lane check - `a_claimed_request_is_refused_by_name_and_nothing_moves` fails with the
//!     file in `withdrawn/` and a running effect abandoned;
//!   * drop `next_step` from `pending_lines` - the status test fails on the missing id and the missing
//!     withdraw command, which is the reported line;
//!   * settle a withdrawn protocol deploy through the legacy outcome record only - the state this door was in
//!     before the review of 18/11 - and the protocol test fails with the deploy still `held`, no terminal phase
//!     anywhere and nothing queued for the session that asked.

use super::*;

/// A home of this test's own: `sentinel_dir()` is derived from `WASM_AGENT_HOME`, so every path the verb
/// touches lands here and nothing can reach the operator's real sentinel state.
struct Scratch {
    home: PathBuf,
}

impl Scratch {
    fn new(label: &str) -> Scratch {
        let home = std::env::temp_dir().join(format!("wa-sentinel-withdraw-{label}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).expect("scratch home");
        std::env::set_var("WASM_AGENT_HOME", &home);
        Scratch { home }
    }

    /// Write a queued request under the name `request` gives it.
    fn queue(&self, id: &str, request: &Value) -> PathBuf {
        let path = sentinel_dir().join("requests").join(format!("{id}.json"));
        std::fs::write(&path, serde_json::to_vec(request).expect("request json")).expect("write the request");
        path
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        std::env::remove_var("WASM_AGENT_HOME");
        std::env::remove_var("WASM_AGENT_PORT");
        std::env::remove_var("WASM_SENTINEL_OBSERVE_GRACE");
        let _ = std::fs::remove_dir_all(&self.home);
    }
}

const ID: &str = "1700000000000000000-4242-00000000000000000000";

/// The audit lines this withdrawal wrote, and only those: one action, one line.
fn audit_lines(id: &str) -> Vec<String> {
    std::fs::read_to_string(log_path()).unwrap_or_default()
        .lines()
        .filter(|line| {
            let mut fields = line.split('\t');
            fields.next();
            fields.next() == Some("withdraw") && fields.next() == Some(id)
        })
        .map(str::to_string)
        .collect()
}

/// 1. A queued request leaves the queue, is kept, is recorded, and is audited once.
#[test]
fn a_queued_request_is_withdrawn_once_with_one_audit_line() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let scratch = Scratch::new("queued");
    let asked = json!({"verb":"deploy","session":"s-1","prompt":"verify the deploy","queued_at":1_700_000_000u64});
    let queued = scratch.queue(ID, &asked);

    // Through the CLI door, because that is the door the operator has: `request withdraw <id> --reason TEXT`.
    request(&["withdraw".to_string(), ID.to_string(), "--reason".to_string(), "no longer needed".to_string()])
        .expect("a queued request can be withdrawn");

    // Out of the queue: no watcher tick can claim it now...
    assert!(!queued.exists(), "the request must leave requests/, or the next watcher tick performs it");
    // ...kept, in a lane that says what happened to it, unmodified.
    let withdrawn = sentinel_dir().join("withdrawn").join(format!("{ID}.json"));
    let stored: Value = serde_json::from_slice(&std::fs::read(&withdrawn).expect("the request is kept, not deleted")).unwrap();
    assert_eq!(stored, asked, "the request file is evidence and is moved, not rewritten");

    // The observation says withdrawn, so `status` does not keep offering a row that cannot happen.
    let record: Value = serde_json::from_slice(&std::fs::read(queue::dir().join(format!("{ID}.json"))).expect("queue record")).unwrap();
    assert_eq!(record["state"], "withdrawn");
    assert_eq!(record["verb"], "deploy");
    assert!(record["detail"].as_str().unwrap_or("").contains("no longer needed"), "the reason is recorded: {}", record["detail"]);

    // One audit line, naming the request and the reason it was given.
    let lines = audit_lines(ID);
    assert_eq!(lines.len(), 1, "one withdrawal, one audit line: {lines:?}");
    assert!(lines[0].ends_with("\tno longer needed"), "the reason is on the audit line: {}", lines[0]);

    // And it cannot be withdrawn twice: the second answer is about where it is, not about an effect.
    let again = withdraw_request(ID, "again").unwrap_err().to_string();
    assert!(again.starts_with("withdraw_not_queued:"), "a second withdraw says where the request is: {again}");
    assert!(again.contains("withdrawn/"), "and names the lane: {again}");
    assert_eq!(audit_lines(ID).len(), 1, "a refused withdrawal is not an action and writes no audit line");
}

/// 2. A claimed request is refused by name: the watcher is performing it, and nothing moves.
#[test]
fn a_claimed_request_is_refused_by_name_and_nothing_moves() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let _scratch = Scratch::new("claimed");
    let claimed = sentinel_dir().join("claimed").join(format!("{ID}.json"));
    std::fs::write(&claimed, serde_json::to_vec(&json!({"verb":"restart","queued_at":1_700_000_000u64})).unwrap()).unwrap();

    let error = request(&["withdraw".to_string(), ID.to_string()]).unwrap_err().to_string();
    assert!(error.starts_with("withdraw_refused_claimed:"), "the refusal names the state: {error}");
    assert!(error.contains(ID), "and the request: {error}");
    assert!(claimed.exists(), "a claimed request is never moved out from under the watcher");
    assert!(!sentinel_dir().join("withdrawn").join(format!("{ID}.json")).exists(), "nothing was withdrawn");
    assert!(audit_lines(ID).is_empty(), "a refusal is not an action, so it is not in the withdraw audit");
}

/// 3. `status` prints the id and both actions for a held request - and reading it claims nothing.
#[test]
fn status_names_the_unblock_and_the_withdraw_for_a_held_request() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let scratch = Scratch::new("status");
    let queued_at = 1_700_000_000u64;
    let queued = scratch.queue(ID, &json!({
        "verb": "deploy",
        "queued_at": queued_at,
        "target_commit": "0123456789abcdef0123456789abcdef01234567",
    }));

    let lines = pending_lines(&sentinel_dir().join("requests"), queued_at + 120, Some(false), true, true);
    assert_eq!(lines.len(), 1, "one waiting request, one line: {lines:?}");
    let line = &lines[0];
    assert!(line.contains("held: node busy"), "the reason it has not run is still there: {line}");
    assert!(line.contains(ID), "the line names the request the operator has to name: {line}");
    assert!(
        line.contains("next: end the turn (no further tool calls) so the node goes idle, and the next watcher tick runs it"),
        "how to unblock it: {line}"
    );
    assert!(
        line.contains(&format!("or withdraw it: wa-sentinel request withdraw {ID}")),
        "how to drop it: {line}"
    );
    assert!(!line.contains('\n'), "one request, one line: {line:?}");
    assert!(queued.exists(), "a status line claims nothing: the request is still in the box");

    // A request nothing holds says so, and still names the withdraw: it is always the operator's to drop.
    let ready = pending_lines(&sentinel_dir().join("requests"), queued_at + 120, Some(true), true, true);
    assert!(ready[0].contains("nothing blocks it: the next watcher tick runs it"), "{:?}", ready[0]);
    assert!(ready[0].contains("wa-sentinel request withdraw"), "{:?}", ready[0]);
}

/// 4. Every other answer is by name: an id that names nothing, a finished request, a malformed id, two ids.
#[test]
fn every_other_answer_is_refused_by_name() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let scratch = Scratch::new("refusals");
    let unknown = withdraw_request("1799999999999999999-1-00000000000000000000", "why not").unwrap_err().to_string();
    assert!(unknown.starts_with("withdraw_unknown_request:"), "{unknown}");
    assert!(unknown.contains("nothing was moved"), "{unknown}");
    let invalid = withdraw_request("../../etc/passwd", "why not").unwrap_err().to_string();
    assert!(invalid.starts_with("withdraw_request_id_invalid:"), "{invalid}");
    assert!(scratch.home.exists(), "the scratch home is the only thing this test touched");

    // A settled request is refused by the lane it is in, so "nothing happened" is never the answer.
    let done = sentinel_dir().join("done").join(format!("{ID}.json"));
    std::fs::write(&done, b"{}").unwrap();
    let settled = withdraw_request(ID, "why not").unwrap_err().to_string();
    assert!(settled.starts_with("withdraw_not_queued:"), "{settled}");
    assert!(settled.contains("done/"), "{settled}");

    // Two ids are two requests, and the verb performs one; no id is no request at all.
    let two = request(&["withdraw".to_string(), ID.to_string(), ID.to_string()]).unwrap_err().to_string();
    assert!(two.contains("one request id"), "{two}");
    let none = request(&["withdraw".to_string()]).unwrap_err().to_string();
    assert!(none.contains("needs the id of the request"), "{none}");
}

/// 5. A withdrawn deploy is not left for the watchdog to report silent: its outcome record is settled.
#[test]
fn withdrawing_a_deploy_settles_its_outcome_instead_of_leaving_it_silent() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let scratch = Scratch::new("deploy-outcome");
    let request_value = json!({
        "verb": "deploy",
        "session": "session-77",
        "prompt": "verify the deploy",
        "reason": "install the fix",
        "queued_at": 1_700_000_000u64,
    });
    scratch.queue(ID, &request_value);
    deploy_outcome::open(ID, &request_value).expect("the deploy names a session, so it has an outcome record");

    withdraw_request(ID, "the install is no longer wanted").expect("a queued deploy can be withdrawn");

    let record: Value = serde_json::from_slice(&std::fs::read(deploy_outcome::dir().join(format!("{ID}.json"))).expect("outcome record")).unwrap();
    assert_eq!(record["state"], "settled", "a withdrawn deploy is settled, not pending for the watchdog: {record}");
    assert_eq!(record["outcome"], "failure");
    assert!(record["detail"].as_str().unwrap_or("").contains("withdrawn"), "the record says why: {}", record["detail"]);
    // The one notice it owes the session is in the box, under the key that keeps it single.
    let notice: Value = serde_json::from_slice(&std::fs::read(sentinel_dir().join("requests").join(format!("deploy-return-{ID}.json"))).expect("the session is told")).unwrap();
    assert_eq!(notice["verb"], "wake");
    assert_eq!(notice["session"], "session-77");
    assert!(notice["prompt"].as_str().unwrap_or("").contains("withdrawn"), "the session is told it was withdrawn: {}", notice["prompt"]);
}

/// 6. A withdrawn PROTOCOL deploy is reported by its own return engine, and the withdrawal is what it reports.
///
/// The defect this pins (review of 18/11, item 6): withdraw_request settled a legacy deploy's outcome record only,
/// and a protocol deploy has none - deploy_outcome::open is deliberately not called for one. So a withdrawn
/// protocol deploy kept acting like a live one: state.json stayed held/accepted, the return engine observed a
/// deploy that could never happen, and the session that asked never received a terminal answer. Only the owner
/// lookup and the job store are stood in for here (a private listener, never the node this machine really runs);
/// the queue, the intake, the withdrawal, the lane and the engine are the real ones.
#[test]
fn withdrawing_a_protocol_deploy_gives_its_session_a_terminal_report() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let scratch = Scratch::new("protocol-withdraw");
    // A directory holding an owed report is never retired, and this proves it with no grace at all.
    std::env::set_var("WASM_SENTINEL_OBSERVE_GRACE", "0");
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("a private owner lookup");
    listener.set_nonblocking(true).expect("nonblocking accept");
    let port = listener.local_addr().unwrap().port();
    std::env::set_var("WASM_AGENT_PORT", port.to_string());
    let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let serving = stop.clone();
    let server = std::thread::spawn(move || {
        while !serving.load(std::sync::atomic::Ordering::SeqCst) {
            match listener.accept() {
                Ok((mut stream, _)) => {
                    stream.set_nonblocking(false).unwrap();
                    stream.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
                    let mut buffer = [0; 4096];
                    let _ = std::io::Read::read(&mut stream, &mut buffer);
                    let body = r#"{"session":{"id":"parent","user_id":"owner"}}"#;
                    let _ = std::io::Write::write_all(&mut stream, format!(
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).as_bytes());
                }
                Err(_) => std::thread::sleep(Duration::from_millis(2)),
            }
        }
    });
    // The hook the engine delivers through: a protocol deploy is reported by it and by nothing else.
    let store = jobs::store();
    let definition: Value = serde_json::from_str(include_str!("../../../jobs/on-sentinel-return.json")).unwrap();
    store.put(&definition).unwrap();
    store.enable("onSentinelReturn", true).unwrap();

    let asked = json!({
        "verb": "deploy", "id": ID, "expected_sha": "a".repeat(40), "queued_at": now_epoch(),
        "session": "parent", "owner": "owner", "reason": "install the fix",
    });
    scratch.queue(ID, &asked);
    // The real intake: intent.json and ack.json, and a held state. Nothing writes binding.json until admit.
    deploy_protocol::intake(&asked, ID).expect("intake accepts the protocol request");
    let dir = sentinel_dir().join("deploy-protocol").join(ID);
    assert!(!dir.join("binding.json").exists(), "a withdrawable protocol deploy was never admitted");
    let held: Value = serde_json::from_slice(&std::fs::read(dir.join("state.json")).unwrap()).unwrap();
    assert_eq!(held["phase"], "held", "the state the defect left behind: {held}");

    withdraw_request(ID, "the install is no longer wanted").expect("a queued protocol deploy can be withdrawn");

    // 1. The withdrawal is recorded in the deploy's own directory, which is what makes it durable.
    let state: Value = serde_json::from_slice(&std::fs::read(dir.join("state.json")).unwrap()).unwrap();
    assert_eq!(state["phase"], "withdrawn", "the deploy stops claiming to be waiting: {state}");
    assert!(state["detail"].as_str().unwrap_or("").contains("no longer wanted"), "{}", state["detail"]);

    // 2. The lane turns it into a terminal return event instead of observing a deploy that cannot happen.
    let mut lane = observation::Observations::load();
    lane.pass();
    let journal_path = dir.join("returns").join(format!("{ID}-0.json"));
    let journal: Value = serde_json::from_slice(&std::fs::read(&journal_path).expect("the session is owed a return")).unwrap();
    assert_eq!(journal["phase"], "failed", "terminal, not another held: {journal}");
    assert_eq!(journal["parent"], "parent");
    assert!(journal["detail"].as_str().unwrap_or("").contains("withdrawn"), "the report says what happened: {journal}");
    let observed: Value = serde_json::from_slice(&std::fs::read(dir.join("installation-observation.json")).unwrap()).unwrap();
    assert_eq!(observed["phase"], "failed", "the installation observation is terminal too: {observed}");
    assert!(dir.join("pending-return.json").is_file(), "and the one event is queued for the parent that asked");

    // 3. One report, one immutable slot: further ticks observe the same deploy and never add a second report, and
    //    the directory is not retired - what was asked and withdrawn stays where a reader can find it.
    let before = std::fs::read(&journal_path).unwrap();
    for _ in 0..20 {
        lane.pass();
    }
    assert_eq!(std::fs::read(&journal_path).unwrap(), before, "an immutable return is never rewritten");
    let slots = std::fs::read_dir(dir.join("returns")).unwrap().count();
    assert_eq!(slots, 1, "one deploy, one return slot, found {slots}");
    assert!(dir.is_dir(), "a directory that owes a report is never retired: {}", dir.display());

    stop.store(true, std::sync::atomic::Ordering::SeqCst);
    server.join().unwrap();
}
