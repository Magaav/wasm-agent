//! The publish loop as an operator has to read it, and how to falsify each claim.
//!
//! The concern, in the words it was reported in: *a deploy request is written, `wa-sentinel status` says
//! only `requests: 1 waiting`, and the deploy is deferred with `maintenance-deferred ... the node is busy: a
//! run, a subagent or an operation is in flight`. A deploy restarts the node, so it can only run when the
//! node is idle - and a coordinator that keeps issuing tool calls is never idle, so its own request starves.
//! Three times in one day the coordinator then reported "queued" as "deployed".
//!
//! What is proved here, without a live node:
//!
//!   1. a waiting request is one line naming its verb, its target commit (or that none was recorded), when it
//!      was queued, and why it is still waiting - the same `hold_for` classification the dispatcher logs;
//!   2. reading that line claims nothing: the request file is still in the box afterwards;
//!   3. the commit recorded when a deploy was written does not follow main when main moves - so a later
//!      `status` still says what *that* request asked to install;
//!   4. `status` names the node (up/down, port, pid) and the sentinel in one line each, with no `/health`
//!      JSON in them - that document is what `wa-sentinel health` prints, verbatim, and what it refuses to
//!      print when the node is down.
//!
//! Falsification, each run by hand and reported with its FAIL line:
//!
//!   * revert `status` to the count only (drop the `pending_lines` loop) - nothing in this file can fail,
//!     which is exactly the state that was reported; the check is the report below, not these tests;
//!   * make `pending_lines` print the count instead of the fields (one line `N waiting`) -
//!     `a_waiting_request_is_one_line_of_facts` fails on the missing verb/commit/time/hold and prints the
//!     line it did get;
//!   * make `pending_requests` read `target_commit` from git instead of from the request file -
//!     `the_recorded_commit_survives_a_later_main_move` fails with the moved commit in place of the recorded
//!     one.

use super::*;

/// A directory of this test's own, removed when the test ends.
struct Scratch {
    dir: PathBuf,
}

impl Scratch {
    fn new(label: &str) -> Scratch {
        let dir = std::env::temp_dir().join(format!("wa-publish-loop-{}-{label}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("scratch directory");
        Scratch { dir }
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// A request file with the name shape `request` writes: `<epoch-nanos>-<pid>-<sequence>.json`.
fn write_request(dir: &Path, stamp: &str, request: &Value) -> PathBuf {
    std::fs::create_dir_all(dir).expect("requests directory");
    let path = dir.join(format!("{stamp}.json"));
    std::fs::write(&path, serde_json::to_vec(request).expect("request json")).expect("write the request");
    path
}

fn git(root: &Path, args: &[&str]) -> String {
    let output = std::process::Command::new("git")
        .arg("-C")
        .arg(root)
        .args(args)
        .env("GIT_AUTHOR_NAME", "wa-publish-loop-test")
        .env("GIT_AUTHOR_EMAIL", "wa-publish-loop-test@example.invalid")
        .env("GIT_COMMITTER_NAME", "wa-publish-loop-test")
        .env("GIT_COMMITTER_EMAIL", "wa-publish-loop-test@example.invalid")
        .output()
        .expect("git runs");
    assert!(
        output.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

const RECORDED: &str = "0123456789abcdef0123456789abcdef01234567";

/// 1. A waiting request is a line of facts, in the words the dispatcher and the operator both use.
#[test]
fn a_waiting_request_is_one_line_of_facts() {
    let scratch = Scratch::new("facts");
    let queued_at = 1_700_000_000u64;
    write_request(
        &scratch.dir,
        "1700000000000000000-4242-00000000000000000000",
        &json!({
            "verb": "deploy",
            "queued_at": queued_at,
            "target_commit": RECORDED,
            "reason": "install the publish-loop fix",
        }),
    );

    let lines = pending_lines(&scratch.dir, queued_at + 120, Some(false), true, true);
    assert_eq!(lines.len(), 1, "one waiting request is one line: {lines:?}");
    let line = &lines[0];
    assert_eq!(
        line,
        "  waiting  deploy  target commit 0123456789abcdef0123456789abcdef01234567  \
queued 2023-11-14T22:13:20Z (2m ago)  held: node busy",
        "the line must carry verb, commit, queue time and the hold reason"
    );
    assert!(!line.contains('\n'), "one request, one line: {line:?}");
}

/// A request that recorded no commit says so, and an older file without `queued_at` still reports when it was
/// queued - from the name the writer chose, which is the queue time in nanoseconds.
#[test]
fn a_request_without_a_commit_says_so_and_takes_its_time_from_its_name() {
    let scratch = Scratch::new("no-commit");
    write_request(
        &scratch.dir,
        "1700000000123456789-4242-00000000000000000000",
        &json!({"verb": "restart", "reason": "pick up the rebuilt node"}),
    );

    let lines = pending_lines(&scratch.dir, 1_700_000_060, Some(true), true, true);
    assert_eq!(lines.len(), 1, "{lines:?}");
    assert!(lines[0].contains("no commit recorded"), "{}", lines[0]);
    assert!(lines[0].contains("2023-11-14T22:13:20Z"), "{}", lines[0]);
    assert!(lines[0].contains("ready:"), "an idle node holds nothing: {}", lines[0]);
}

/// The hold label is the dispatcher's own classification: busy holds and says so, an idle node holds nothing,
/// and a verb that never waits for idle says that instead of pretending to be held.
#[test]
fn the_hold_label_is_the_dispatch_classification() {
    assert_eq!(hold_label("deploy", Some(false), true), "held: node busy");
    assert!(hold_label("deploy", None, true).starts_with("held: the node answers"));
    assert!(hold_label("deploy", Some(true), true).starts_with("ready:"));
    assert!(hold_label("deploy", None, false).starts_with("ready: the node is down"));
    assert!(hold_label("wake", Some(false), true).starts_with("does not wait for idle"));
}

/// Reading the queue is not claiming it. If `status` ever removed what it reported, the report would be the
/// cause of the effect it describes.
#[test]
fn reporting_a_waiting_request_leaves_it_in_the_box() {
    let scratch = Scratch::new("read-only");
    let request = json!({"verb": "deploy", "queued_at": 1_700_000_000u64, "target_commit": RECORDED});
    let path = write_request(&scratch.dir, "1700000000000000000-4242-00000000000000000000", &request);

    let _ = pending_lines(&scratch.dir, 1_700_000_100, Some(false), true, false);
    assert!(path.is_file(), "status must not claim a request it only reported");
    let after: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(after, request, "status must not rewrite the request it reported");
}

/// 3. This is the point of recording the commit at request time: main moves, the request keeps saying what it
/// was written to install.
#[test]
fn the_recorded_commit_survives_a_later_main_move() {
    let scratch = Scratch::new("main-moved");
    let repo = scratch.dir.join("repo");
    std::fs::create_dir_all(&repo).expect("repo directory");
    git(&repo, &["init", "-q"]);
    git(&repo, &["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-q", "-m", "first"]);
    let first = git(&repo, &["rev-parse", "HEAD"]);
    git(&repo, &["update-ref", "refs/remotes/origin/main", &first]);
    assert_eq!(deploy_protocol::target_commit_at(&repo).unwrap(), first);

    // The request is written now, while main is `first` - and records that commit, not a pointer to main.
    let requests = scratch.dir.join("requests");
    write_request(
        &requests,
        "1700000000000000000-4242-00000000000000000000",
        &json!({"verb": "deploy", "queued_at": 1_700_000_000u64, "target_commit": first}),
    );

    // Main moves on. The tree now reads as the newer commit; the queued request still names the older one.
    git(&repo, &["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-q", "-m", "second"]);
    let second = git(&repo, &["rev-parse", "HEAD"]);
    assert_ne!(first, second);
    git(&repo, &["update-ref", "refs/remotes/origin/main", &second]);
    assert_eq!(deploy_protocol::target_commit_at(&repo).unwrap(), second, "main has moved");

    let lines = pending_lines(&requests, 1_700_000_300, Some(false), true, true);
    assert_eq!(lines.len(), 1, "{lines:?}");
    assert!(lines[0].contains(&first), "the recorded commit must survive the move: {}", lines[0]);
    assert!(!lines[0].contains(&second), "status must not re-read main: {}", lines[0]);
}

/// The timestamp an operator reads is UTC and unambiguous, and it is the queue time, not "now".
#[test]
fn queue_times_are_utc_stamps() {
    assert_eq!(utc_stamp(0), "1970-01-01T00:00:00Z");
    assert_eq!(utc_stamp(86_400), "1970-01-02T00:00:00Z");
    assert_eq!(utc_stamp(1_700_000_000), "2023-11-14T22:13:20Z");
    assert_eq!(age(1_700_000_000, 1_699_999_990), "10s ago");
    assert_eq!(age(1_700_000_000, 1_699_999_820), "3m ago");
    assert_eq!(age(1_700_000_000, 1_699_992_800), "2h ago");
    assert_eq!(age(1_700_000_000, 1_699_913_600), "1d ago");
}

/// 4. The other half of the same read: `status` says whether the node is up, on which port and under which
/// pid, and says it in one line. The `/health` document it used to inline here is why the coordinator read
/// past four kilobytes of JSON to find `0 waiting`; the test that can fail without a live node is the line.
#[test]
fn the_node_line_is_up_down_port_and_pid_without_the_health_document() {
    let up = node_line(8799, true, Some(4242));
    assert_eq!(up, "node:      up    port 8799  pid 4242");
    let down = node_line(8799, false, None);
    assert_eq!(down, "node:      down  port 8799  no process on the port");
    // A node that answers but whose listener pid cannot be read says that rather than inventing one.
    let unreadable = node_line(8799, true, None);
    assert!(unreadable.contains("pid unknown"), "{unreadable}");
    for line in [&up, &down, &unreadable] {
        assert!(line.starts_with("node:"), "{line}");
        assert!(!line.contains('{') && !line.contains("capabilities"), "no JSON in a status line: {line}");
        assert_eq!(line.lines().count(), 1, "one fact, one line: {line:?}");
    }
}

/// The sentinel line carries the same three facts, except the port: a sentinel supervises, it does not
/// listen, so the line says so instead of leaving a blank. `verify-install.sh` reads `watching (pid N)`
/// from exactly this text, which is why the words are asserted here.
#[test]
fn the_sentinel_line_is_up_down_pid_and_says_it_has_no_port() {
    let up = sentinel_line(true, Some(77), "");
    assert!(up.starts_with("sentinel:  up"), "{up}");
    assert!(up.contains("watching (pid 77)"), "{up}");
    assert!(up.contains("no port of its own"), "{up}");
    let down = sentinel_line(false, None, "the lifetime lock is free and no pid answers");
    assert!(down.starts_with("sentinel:  down"), "{down}");
    assert!(down.contains("not running"), "{down}");
    // The reason is the fact that was missing when six deploys refused a live watcher: "not running" alone
    // says nothing about which evidence was absent.
    assert!(down.contains("the lifetime lock is free"), "{down}");
    let legacy = sentinel_line(true, Some(4242), "a build that predates the lock");
    assert!(legacy.contains("watching (pid 4242)"), "{legacy}");
    assert!(legacy.contains("predates the lock"), "{legacy}");
    for line in [&up, &down, &legacy] {
        assert!(!line.contains('{'), "no JSON in a status line: {line}");
        assert_eq!(line.lines().count(), 1, "one fact, one line: {line:?}");
    }
}

/// 5. The document did not disappear: it moved to `wa-sentinel health`, which prints the body the node sent,
/// byte for byte. A re-serialised copy would be the verifier's rendering of the node, not the node's report -
/// and the point of the split is that a script can parse the real one.
#[test]
fn the_health_verb_prints_the_node_body_verbatim() {
    let _alone = ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("a free port");
    let port = listener.local_addr().unwrap().port();
    let previous = std::env::var_os("WASM_AGENT_PORT");
    std::env::set_var("WASM_AGENT_PORT", port.to_string());
    // Deliberate spacing and key order: verbatim means this exact string comes back, not a pretty-print.
    let body = "{\"ok\":true,\"queue\":0,\"current\":null,\"workers\":[],\"spacer\":\"  keep\\tbytes  \"}";
    let sent = body.to_string();
    // Serve whatever connections the client opens until it stops asking: pinning the accept count to one
    // per call would make the fixture, not the verb, the thing under test.
    let worker = std::thread::spawn(move || {
        use std::io::{Read, Write};
        listener.set_nonblocking(true).expect("non-blocking fixture listener");
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
        while std::time::Instant::now() < deadline {
            match listener.accept() {
                Ok((mut stream, _)) => {
                    let _ = stream.set_read_timeout(Some(std::time::Duration::from_secs(1)));
                    let mut buffer = [0u8; 2048];
                    let _ = stream.read(&mut buffer);
                    let _ = write!(
                        stream,
                        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{sent}",
                        sent.len()
                    );
                }
                Err(_) => std::thread::sleep(std::time::Duration::from_millis(10)),
            }
        }
    });
    assert_eq!(health_body().as_deref(), Some(body), "the verb prints the node's bytes, not ours");
    let parsed: Value = serde_json::from_str(body).expect("the body the node sent is JSON");
    assert_eq!(parsed["queue"], json!(0));
    assert!(health().is_some(), "the same body parses into the activity contract");
    worker.join().expect("the fixture server finished");
    match previous {
        Some(value) => std::env::set_var("WASM_AGENT_PORT", value),
        None => std::env::remove_var("WASM_AGENT_PORT"),
    }
}

/// And when the node is down, `health` fails and names the URL it could not read - it does not print an empty
/// document that a caller could mistake for a healthy one.
#[test]
fn the_health_verb_fails_loudly_when_the_node_does_not_answer() {
    let _alone = ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    // Bind then drop: the port is free, so nothing answers on it.
    let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let previous = std::env::var_os("WASM_AGENT_PORT");
    std::env::set_var("WASM_AGENT_PORT", port.to_string());
    let error = health_verb().expect_err("a down node is not a health report");
    assert!(format!("{error:#}").contains("/health"), "the failure names what it could not read: {error:#}");
    assert!(health().is_none());
    match previous {
        Some(value) => std::env::set_var("WASM_AGENT_PORT", value),
        None => std::env::remove_var("WASM_AGENT_PORT"),
    }
}

/// `status` falls back to the watcher's own `watch pid N` audit line when the lifetime lock proves a watcher
/// but its pid file cannot be read. Measured 2026-10-20: a deploy's own child was in exactly that state, and
/// the deploy refused a live watcher for an afternoon because the line had no number in it.
#[test]
fn the_watcher_pid_falls_back_to_the_watchers_own_start_line() {
    let log = "1789760643\twatch\tpid 17932\tsentinel started\n\
               1789760666\tnode-down\tport 8799\tno answer to /health\n\
               1789760673\tstart\tC:/wa.exe\tthe node was stopped\n";
    assert_eq!(super::watched_pid_from_log(log), Some(17932), "the watcher's own line names it");
    let newer = format!("{log}1789760999\twatch\tpid 4040\tsentinel started\n");
    assert_eq!(super::watched_pid_from_log(&newer), Some(4040), "the newest watch line wins");
    assert_eq!(super::watched_pid_from_log(""), None, "an empty log names nobody");
    assert_eq!(
        super::watched_pid_from_log("1789760643\twatcher\tpid 1\tx\n"),
        None,
        "only the `watch` verb counts - a near miss is not a pid"
    );
}
