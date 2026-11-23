//! The one line that says whether transcription, posting and the index are working, and when each
//! last did.
//!
//! WHY THIS EXISTS. The operator's report on 23/11 was "whatsapp auto transcription is broken" and
//! nothing in the node could answer "when did it last work": the component wrote a line per note and
//! nothing else, so the last successful transcription, the last posted reply and the last indexed
//! record were facts an auditor had to dig out of a 2 700-line service log by hand (and the answer was
//! in there: `transcript ready` at 12:04:19Z, then nothing). A component that stops posting while it
//! keeps transcribing looks exactly like a broken one from outside, which is what it was taken for.
//!
//! Print it once at start (so a restart is dated) and then every `health_every_seconds` (default 300).
//! The line is the same shape every time, so a gap in it is visible by itself.
//!
//! What it never carries: a chat JID, a message id, and any text. Counts, a reason code and times
//! only - the rule `wa-transcript` keeps (src/privacy.rs, and its test that no log line spells an id).
use std::cell::RefCell;

/// What one component instance has done since it started, as counters and the time of the last one.
///
/// A time is `None` until the thing happens, so "never" is a state the line can say instead of a zero
/// that reads like "just now".
#[derive(Default, Clone, Debug, PartialEq, Eq)]
pub struct Health {
    pub transcripts_ok: u64,
    pub last_transcript_ms: Option<i64>,
    pub last_transcript_chars: usize,
    pub transcripts_failed: u64,
    pub last_failure_ms: Option<i64>,
    /// The last refusal in the component's own words (`download`, `recognize:<reason>`), never text.
    pub last_failure_reason: String,
    pub posts_ok: u64,
    pub last_post_ms: Option<i64>,
    pub records_indexed: u64,
    pub last_index_ms: Option<i64>,
    /// Deletion notices this node could attach to a stored message (`crate::notices`).
    pub notices_matched: u64,
    /// Deletion notices it could NOT attach to one: a defect counter, never a block (23/11).
    pub notices_unmatched: u64,
    pub last_notice_ms: Option<i64>,
    pub last_unmatched_ms: Option<i64>,
}

impl Health {
    /// The line. `posting` is the configured mode (`on`/`off`), passed in because it is the one fact
    /// that decides whether a transcript is ever delivered, and a node in shadow mode has to say so
    /// on every line rather than only at start.
    pub fn line(&self, posting: &str) -> String {
        fn at(ms: Option<i64>) -> String {
            ms.map(crate::view::iso).unwrap_or_else(|| "-".to_string())
        }
        let reason = if self.last_failure_reason.is_empty() { "-" } else { self.last_failure_reason.as_str() };
        format!(
            "health: v=1 transcripts ok={} last={} chars={} failed={} last_failure={} reason={reason} posting={posting} posted={} last_post={} index written={} last={} notices matched={} unmatched={} last_notice={} last_unmatched={}",
            self.transcripts_ok,
            at(self.last_transcript_ms),
            self.last_transcript_chars,
            self.transcripts_failed,
            at(self.last_failure_ms),
            self.posts_ok,
            at(self.last_post_ms),
            self.records_indexed,
            at(self.last_index_ms),
            self.notices_matched,
            self.notices_unmatched,
            at(self.last_notice_ms),
            at(self.last_unmatched_ms),
        )
    }
}

thread_local! {
    // Single-threaded guest: the runtime never crosses a thread (see the runtime impl at the bottom of
    // guest.rs), and every other per-instance cell in this component is a `thread_local!` for the same
    // reason. Nothing here is a lock, so no await can ever hold it.
    static HEALTH: RefCell<Health> = RefCell::new(Health::default());
}

/// One voice note transcribed, with how much was said in it.
pub fn transcript_ok(chars: usize, at_ms: i64) {
    HEALTH.with(|cell| {
        let mut health = cell.borrow_mut();
        health.transcripts_ok += 1;
        health.last_transcript_ms = Some(at_ms);
        health.last_transcript_chars = chars;
    });
}

/// One voice note that will not be transcribed, and why - the reason a chat may see as an alert.
pub fn transcript_failed(reason: &str, at_ms: i64) {
    HEALTH.with(|cell| {
        let mut health = cell.borrow_mut();
        health.transcripts_failed += 1;
        health.last_failure_ms = Some(at_ms);
        health.last_failure_reason = reason.to_string();
    });
}

/// One transcript posted (or one edit of a post-then-edit message: a delivered reply either way).
pub fn posted(at_ms: i64) {
    HEALTH.with(|cell| {
        let mut health = cell.borrow_mut();
        health.posts_ok += 1;
        health.last_post_ms = Some(at_ms);
    });
}

/// One index pass that wrote `records` records (zero is a pass that had nothing new, not a failure).
pub fn indexed(records: usize, at_ms: i64) {
    HEALTH.with(|cell| {
        let mut health = cell.borrow_mut();
        health.records_indexed += records as u64;
        health.last_index_ms = Some(at_ms);
    });
}

/// One deletion notice that found its message. The counter is the proof that matching works; without it a
/// node that could not match anything would look exactly like a node with nothing to match.
pub fn notice_matched(at_ms: i64) {
    HEALTH.with(|cell| {
        let mut health = cell.borrow_mut();
        health.notices_matched += 1;
        health.last_notice_ms = Some(at_ms);
    });
}

/// One deletion notice that named no message this node holds. It is a defect counter and NOT a block
/// (the owner's rule: a notice never holds a chat), so it is counted, timed, and carried on the line.
pub fn notice_unmatched(at_ms: i64) {
    HEALTH.with(|cell| {
        let mut health = cell.borrow_mut();
        health.notices_unmatched += 1;
        health.last_notice_ms = Some(at_ms);
        health.last_unmatched_ms = Some(at_ms);
    });
}

/// What a previous run left in the ledger: a restart must not reset a defect counter to zero, or the
/// line would say the node has never failed to match a notice it has been failing to match for days.
pub fn notices_restored(ledger: crate::notices::Ledger) {
    HEALTH.with(|cell| {
        let mut health = cell.borrow_mut();
        health.notices_matched = ledger.matched;
        health.notices_unmatched = ledger.unmatched;
        health.last_notice_ms = (ledger.last_ms > 0).then_some(ledger.last_ms);
        health.last_unmatched_ms = (ledger.last_unmatched_ms > 0).then_some(ledger.last_unmatched_ms);
    });
}

/// The line as it stands now.
pub fn line(posting: &str) -> String {
    HEALTH.with(|cell| cell.borrow().line(posting))
}

/// A copy, for a caller that wants the counters rather than the rendering.
pub fn snapshot() -> Health {
    HEALTH.with(|cell| cell.borrow().clone())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A component that has done nothing says so, and does not pretend a zero is a fresh success.
    #[test]
    fn a_fresh_health_says_never_rather_than_just_now() {
        let line = Health::default().line("off");
        assert!(line.contains("transcripts ok=0 last=-"), "{line}");
        assert!(line.contains("posted=0 last_post=-"), "{line}");
        assert!(line.contains("index written=0 last=-"), "{line}");
        assert!(line.contains("posting=off"), "the mode that decides delivery is on every line: {line}");
        assert!(line.contains("reason=-"), "{line}");
    }

    /// The time of the last success is what the operator asked for ("a health line says when the last
    /// transcription succeeded"), so it is a UTC instant and not an age a reader has to date.
    #[test]
    fn the_last_success_is_a_utc_instant_and_the_last_refusal_names_its_reason() {
        let mut health = Health::default();
        health.transcripts_ok = 46;
        health.last_transcript_ms = Some(1_795_435_459_000); // 2026-11-23T12:04:19Z
        health.last_transcript_chars = 174;
        health.transcripts_failed = 1;
        health.last_failure_ms = Some(1_795_400_000_000);
        health.last_failure_reason = "recognize:stt_start".into();
        health.posts_ok = 0;
        health.records_indexed = 1_321;
        health.last_index_ms = Some(1_795_435_460_000);
        let line = health.line("on");
        assert!(line.contains("ok=46 last=2026-11-23T12:04:19Z chars=174"), "{line}");
        assert!(line.contains("failed=1 last_failure=2026-11-23T02:13:20Z reason=recognize:stt_start"), "{line}");
        assert!(line.contains("posting=on posted=0 last_post=-"), "{line}");
        assert!(line.contains("index written=1321 last=2026-11-23T12:04:20Z"), "{line}");
    }

    /// The counters the pipeline updates are the ones the line reads: a success after a refusal keeps
    /// both (the refusal is evidence, not something a later success erases).
    #[test]
    fn a_success_does_not_erase_the_last_refusal_and_each_lane_has_its_own_clock() {
        transcript_failed("download", 1_000);
        transcript_ok(12, 2_000);
        posted(3_000);
        indexed(2, 4_000);
        let health = snapshot();
        assert_eq!(health.transcripts_ok, 1);
        assert_eq!(health.last_transcript_ms, Some(2_000));
        assert_eq!(health.last_transcript_chars, 12);
        assert_eq!(health.transcripts_failed, 1);
        assert_eq!(health.last_failure_ms, Some(1_000));
        assert_eq!(health.last_failure_reason, "download");
        assert_eq!(health.posts_ok, 1);
        assert_eq!(health.last_post_ms, Some(3_000));
        assert_eq!(health.records_indexed, 2);
        assert_eq!(health.last_index_ms, Some(4_000));
        let line = line("on");
        assert!(line.contains("ok=1 last=1970-01-01T00:00:02Z chars=12 failed=1 last_failure=1970-01-01T00:00:01Z reason=download"), "{line}");
    }

    /// The line never spells a chat, a message id or a word of text - the counters are numbers and the
    /// reason is a code the component chose.
    #[test]
    fn the_line_carries_no_address_and_no_text() {
        transcript_ok(1_000, 1_500);
        transcript_failed("recognize:unsupported_language", 1_600);
        let line = line("off");
        for forbidden in ["@g.us", "@s.whatsapp.net", "@lid", "sha256:"] {
            assert!(!line.contains(forbidden), "{forbidden} is in the health line: {line}");
        }
    }
}
