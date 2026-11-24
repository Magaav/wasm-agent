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
queued 2023-11-14T22:13:20Z (2m ago)  held: node busy; next: end the turn (no further tool calls) so the node \
goes idle, and the next watcher tick runs it; or withdraw it: wa-sentinel request withdraw \
1700000000000000000-4242-00000000000000000000",
        "the line must carry verb, commit, queue time, the hold reason and what to do about it"
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
    // Spawns git: hold ENV_LOCK, which the tests that blank PATH hold while they do.
    let _lock = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
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

/// 3b. A checkout that names another source of main (`wa.deployRemote`, the sandbox's host bundle) records
/// that main - it is what deploy.sh builds - and falls back to origin/main when the named ref is absent.
#[test]
fn a_named_deploy_remote_is_the_recorded_main() {
    // Spawns git: hold ENV_LOCK, which the tests that blank PATH hold while they do.
    let _lock = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let scratch = Scratch::new("deploy-remote");
    let repo = scratch.dir.join("repo");
    std::fs::create_dir_all(&repo).expect("repo directory");
    git(&repo, &["init", "-q"]);
    git(&repo, &["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-q", "-m", "published"]);
    let published = git(&repo, &["rev-parse", "HEAD"]);
    git(&repo, &["update-ref", "refs/remotes/origin/main", &published]);
    git(&repo, &["config", "wa.deployRemote", "host"]);
    assert_eq!(deploy_protocol::target_commit_at(&repo).unwrap(), published, "no host/main yet: origin/main");
    git(&repo, &["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-q", "-m", "unpushed"]);
    let unpushed = git(&repo, &["rev-parse", "HEAD"]);
    git(&repo, &["update-ref", "refs/remotes/host/main", &unpushed]);
    assert_eq!(deploy_protocol::target_commit_at(&repo).unwrap(), unpushed, "the named remote's main");
}


/// 3c. THE MEASURED DEFECT (24/11, `work`): the checkout names a `host` bundle whose main is SEVEN DAYS
/// BEHIND origin/main, and the sentinel recorded that stale tip as the target of EVERY request - while
/// `deploy.sh` built HEAD (which was origin/main) and installed `345e51be`. What a request records is what a
/// deploy would install, by the rule stated once in docs/DEPLOY-TARGET.md.
#[test]
fn a_named_main_behind_origin_records_what_a_deploy_would_install() {
    // Spawns git: hold ENV_LOCK, which the tests that blank PATH hold while they do.
    let _lock = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let scratch = Scratch::new("named-main-behind");
    let repo = scratch.dir.join("repo");
    std::fs::create_dir_all(&repo).expect("repo directory");
    git(&repo, &["init", "-q"]);
    git(&repo, &["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-q", "-m", "the bundle tip"]);
    let stale = git(&repo, &["rev-parse", "HEAD"]);
    git(&repo, &["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-q", "-m", "the seven days after it"]);
    let main = git(&repo, &["rev-parse", "HEAD"]);
    git(&repo, &["update-ref", "refs/remotes/origin/main", &main]);
    git(&repo, &["update-ref", "refs/remotes/host/main", &stale]);
    git(&repo, &["config", "wa.deployRemote", "host"]);
    assert_eq!(git(&repo, &["rev-list", "--count", "HEAD..host/main"]), "0",
        "the fixture: HEAD is not behind the bundle, so deploy.sh builds it");
    assert_eq!(git(&repo, &["rev-list", "--count", "host/main..HEAD"]), "1",
        "the fixture: the bundle IS behind HEAD, which is what made every recorded target stale");
    assert_eq!(deploy_protocol::target_commit_at(&repo).unwrap(), main,
        "the recorded target is what a deploy would install (HEAD, which is origin/main) - not the stale bundle main {stale}");
}

/// 3d. THE CASE THE NAMED REMOTE WAS BUILT FOR (the laptop sandbox, 29/10), unchanged: its bundle main is
/// AHEAD of origin/main, because its operator's main arrives there before it is pushed anywhere. HEAD is on
/// that main and behind none of them, so the recorded target is still that main - the same value it recorded
/// before the rule was written down.
#[test]
fn a_named_main_ahead_of_origin_records_that_main() {
    // Spawns git: hold ENV_LOCK, which the tests that blank PATH hold while they do.
    let _lock = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let scratch = Scratch::new("named-main-ahead");
    let repo = scratch.dir.join("repo");
    std::fs::create_dir_all(&repo).expect("repo directory");
    git(&repo, &["init", "-q"]);
    git(&repo, &["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-q", "-m", "published"]);
    let published = git(&repo, &["rev-parse", "HEAD"]);
    git(&repo, &["update-ref", "refs/remotes/origin/main", &published]);
    git(&repo, &["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-q", "-m", "not pushed yet"]);
    let ahead = git(&repo, &["rev-parse", "HEAD"]);
    git(&repo, &["update-ref", "refs/remotes/host/main", &ahead]);
    git(&repo, &["config", "wa.deployRemote", "host"]);
    assert_eq!(git(&repo, &["rev-list", "--count", "HEAD..origin/main"]), "0", "the fixture: HEAD is behind nothing");
    assert_eq!(deploy_protocol::target_commit_at(&repo).unwrap(), ahead,
        "a named main ahead of origin is what deploy.sh builds, and what is recorded");
    assert_ne!(deploy_protocol::target_commit_at(&repo).unwrap(), published,
        "and never origin/main's tip when that is behind the tree");
}

/// 3e. A tree that is on no named main is one deploy.sh refuses, so nothing it holds is a candidate for what
/// will be installed: the record names origin/main - the commit a deploy installs once the tree is fixed.
#[test]
fn a_tree_that_is_on_no_named_main_records_origin_main() {
    // Spawns git: hold ENV_LOCK, which the tests that blank PATH hold while they do.
    let _lock = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let scratch = Scratch::new("not-on-main");
    let repo = scratch.dir.join("repo");
    std::fs::create_dir_all(&repo).expect("repo directory");
    git(&repo, &["init", "-q"]);
    git(&repo, &["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-q", "-m", "main"]);
    let main = git(&repo, &["rev-parse", "HEAD"]);
    git(&repo, &["update-ref", "refs/remotes/origin/main", &main]);
    git(&repo, &["checkout", "-q", "-b", "change/unmerged"]);
    git(&repo, &["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-q", "-m", "the unmerged change"]);
    assert_eq!(git(&repo, &["rev-list", "--count", "HEAD..origin/main"]), "0",
        "the fixture: not behind - the only reason to refuse it is that it is on no main");
    assert_eq!(deploy_protocol::target_commit_at(&repo).unwrap(), main, "origin/main, the commit a deploy installs");
}

/// 3f. THROUGH THE DOOR AN OPERATOR USES, not through the function alone: `request deploy` in that checkout
/// writes the request file the node then reads (`deploy_wait`'s pause line, `installer_outcome`'s verdict),
/// and the `target_commit` in it is what a deploy would install - not the named remote's stale main.
#[test]
fn a_request_written_in_that_checkout_records_what_a_deploy_would_install() {
    // Spawns git and writes a request: hold ENV_LOCK, which every test that touches the environment holds.
    let _lock = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let scratch = Scratch::new("request-written");
    let repo = scratch.dir.join("repo");
    std::fs::create_dir_all(&repo).expect("repo directory");
    git(&repo, &["init", "-q"]);
    git(&repo, &["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-q", "-m", "the bundle tip"]);
    let stale = git(&repo, &["rev-parse", "HEAD"]);
    git(&repo, &["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-q", "-m", "the seven days after it"]);
    let main = git(&repo, &["rev-parse", "HEAD"]);
    git(&repo, &["update-ref", "refs/remotes/origin/main", &main]);
    git(&repo, &["update-ref", "refs/remotes/host/main", &stale]);
    git(&repo, &["config", "wa.deployRemote", "host"]);

    let home = scratch.dir.join("home");
    let install = scratch.dir.join("install");
    std::fs::create_dir_all(&home).expect("scratch home");
    std::fs::create_dir_all(&install).expect("scratch install");
    // The one refusal that matters in a test that writes a request: this is not the node's own store.
    let node_store = std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".wasm-agent").join("sentinel"));
    assert_ne!(Some(home.join(".wasm-agent").join("sentinel")), node_store,
        "the scratch store must never be the node's own sentinel directory");
    let restore: Vec<(&str, Option<std::ffi::OsString>)> = ["WASM_AGENT_HOME", "WA_DEPLOY_ROOT", "WA_INSTALL_DIR"]
        .into_iter()
        .map(|key| (key, std::env::var_os(key)))
        .collect();
    std::env::set_var("WASM_AGENT_HOME", &home);
    std::env::set_var("WA_DEPLOY_ROOT", &repo);
    std::env::set_var("WA_INSTALL_DIR", &install);

    let args: Vec<String> = ["deploy", "--reason", "read the box afterwards"].iter().map(|s| s.to_string()).collect();
    request(&args).expect("the request is written");

    let box_dir = sentinel_dir().join("requests");
    let mut files: Vec<PathBuf> = std::fs::read_dir(&box_dir).expect("the request box")
        .flatten().map(|entry| entry.path()).filter(|path| path.extension().and_then(|e| e.to_str()) == Some("json"))
        .collect();
    files.sort();
    assert_eq!(files.len(), 1, "one request was written: {files:?}");
    let written: Value = serde_json::from_slice(&std::fs::read(&files[0]).expect("the request file")).expect("request json");
    assert_eq!(written["target_commit"], json!(main),
        "the request names what a deploy would install, not the bundle's stale main {stale}: {written}");
    assert_eq!(written.get("expected_sha"), None, "and it demands no commit: the legacy door names no expected SHA");

    for (key, value) in restore {
        match value { Some(v) => std::env::set_var(key, v), None => std::env::remove_var(key) }
    }
}

/// 3g. THE RULE IS STATED ONCE (docs/DEPLOY-TARGET.md) and both halves cite that statement - deploy.sh rule 2,
/// which decides what may be installed, and `target_commit_at`, which records what a request asked for. The two
/// drifted on `work` (24/11) precisely because each carried its own idea of "main"; a citation is not prose a
/// test can judge, but its absence is, and absence is how the next drift starts.
///
/// Read from the files rather than embedded (`include_str!`): a citation that is reverted would then break the
/// crate's compilation instead of failing one test with the sentence below.
#[test]
fn the_target_rule_is_stated_once_and_both_halves_cite_it() {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("..");
    let read = |relative: &str| std::fs::read_to_string(root.join(relative))
        .unwrap_or_else(|error| panic!("{relative} is not readable: {error}"));
    let doc = read("docs/DEPLOY-TARGET.md");
    assert!(doc.contains("## The rule"), "the one statement has its own section");
    assert!(doc.contains("A deploy installs **HEAD**"), "and it says what a deploy installs");
    assert!(read("rust/wa-sentinel/src/deploy_protocol.rs").contains("docs/DEPLOY-TARGET.md"),
        "the sentinel half cites the statement (target_commit_at)");
    assert!(read("scripts/deploy.sh").contains("docs/DEPLOY-TARGET.md"),
        "deploy.sh rule 2 cites the statement");
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
