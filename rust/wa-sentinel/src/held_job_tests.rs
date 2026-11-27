//! WHAT AN INSTALL SAYS IT IS WAITING FOR (Fable 27/11). The line names the held job, its session and how long
//! it can still run - read from the one record a hold publishes. A stale name is worse than no name, so these
//! rows pin the three ways the reader must stay quiet as well as the line itself.
use super::{held_job_line_in, mmss, short_session};
use std::path::PathBuf;

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("wa-held-job-{}-{}", name, std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("scratch dir");
    dir
}

fn write_record(dir: &PathBuf, op: &str, started_at: i64, limit_ms: i64, elapsed_ms: i64, session: &str) {
    let body = format!(
        r#"{{"op":"{}","session":"{}","tool":"bash","started_at":{},"elapsed_ms":{},"limit_ms":{}}}"#,
        op, session, started_at, elapsed_ms, limit_ms
    );
    assert!(std::fs::write(dir.join(format!("codemode-hold-{}.json", op)), body).is_ok());
}

/// The line itself: the job, its session in the eight characters a person quotes, and the time it can still run.
#[test]
fn names_the_job_and_its_remaining_time() {
    let dir = scratch("line");
    write_record(&dir, "op-1795-1-1", 1_000, 300_000, 60_000, "5b6267ee-0a3c-40fb");
    let line = held_job_line_in(&dir, 1_030, 900).expect("a live record answers a line");
    assert_eq!(line, "waiting for op-1795-1-1 of session 5b6267ee, up to 4:00");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A record older than the deploy's own bound answers nothing: naming a job that finished would send an operator
/// to look at work that is not there.
#[test]
fn a_stale_record_answers_nothing() {
    let dir = scratch("stale");
    write_record(&dir, "op-1795-1-2", 1_000, 300_000, 0, "aaaa");
    assert!(held_job_line_in(&dir, 1_000 + 901, 900).is_none());
    let _ = std::fs::remove_dir_all(&dir);
}

/// Two held jobs: the newest is the one named, because it is the one the turn is waiting on last.
#[test]
fn the_newest_held_job_is_named() {
    let dir = scratch("newest");
    write_record(&dir, "op-old", 1_000, 60_000, 0, "aaaa1111");
    write_record(&dir, "op-new", 1_010, 60_000, 0, "bbbb2222");
    let line = held_job_line_in(&dir, 1_020, 900).expect("a live record answers a line");
    assert!(line.contains("op-new"), "{line}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// An unreadable record and an empty session both answer a line a person can read, never a panic and never a
/// blank field.
#[test]
fn unreadable_records_and_missing_sessions_are_named() {
    let dir = scratch("unreadable");
    assert!(std::fs::write(dir.join("codemode-hold-bad.json"), "not json").is_ok());
    assert!(held_job_line_in(&dir, 1_000, 900).is_none());
    write_record(&dir, "op-1795-1-3", 1_000, 60_000, 0, "");
    let line = held_job_line_in(&dir, 1_001, 900).expect("a live record answers a line");
    assert!(line.contains("of session unknown"), "{line}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// The two small formatters, because they are what an operator reads.
#[test]
fn formats_a_person_reads() {
    assert_eq!(mmss(0), "0:00");
    assert_eq!(mmss(59_400), "1:00");
    assert_eq!(mmss(240_000), "4:00");
    assert_eq!(short_session("5b6267ee-0a3c"), "5b6267ee");
    assert_eq!(short_session(""), "unknown");
}
