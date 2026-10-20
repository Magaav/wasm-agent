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
//!      `status` still says what *that* request asked to install.
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
