//! The transcript telemetry a shadow run is compared on: one stable `key=value` line per voice
//! note (`wa-transcript v=1 kind=ready …`), written into the component's own log.
//!
//! Why the log and not a telemetry interface: `wa:kernel@0.2` has no guest-facing telemetry
//! interface (the kernel exports `log`, `lifecycle`, `kv`, … only). The host records what it sees
//! itself - every `wa:kernel` host call, `speech.recognize` included, goes through
//! `node_telemetry::HostCallGuard` with its duration - but the guest cannot add a metric. So the
//! component writes the timings it alone knows (download, first segment, whole recognition, post)
//! as metadata lines, and `scripts/compare-transcripts.mjs` parses them against the Go connector's
//! `journal.db`.
//!
//! Shape, and why it is this shape: `wa-transcript ` then `key=value` pairs separated by single
//! spaces, `key` from the closed set below. A value is one token (no whitespace, no `=`, at most
//! 120 characters), so a parser can split the line with a regular expression without quoting
//! rules, and a reason string that gained a space can never split a line into two fields. There is
//! no field for message or transcript text, at all: `chars` is a count, and every other value is
//! an ID, a state, a reason code or a duration.
//!
//! `chat` and `id` are **digests** (`sha256:` + 32 hex, `crate::privacy`), not the JID and the message
//! id: this is a log line, and a log line outlives the run and travels into issue reports. The digest
//! is still the join key the comparison needs - the same chat is the same mark on every line and in
//! every run - so `scripts/compare-transcripts.mjs` joins the component side against the journal by
//! digesting the journal's ids the same way.
//!
//! Fields (in the order [`Note`] emits them): `v`, `kind`, `chat`, `id`, then whatever the call
//! site adds - `state`, `stage`, `reason`, `download_ms`, `first_segment_ms`, `total_ms`,
//! `recognize_ms`, `since_sent_ms`, `chars`, `segments`, `parts`, `edits`, `first_text_ms`,
//! `streamed`, `posted`. A timing that was not measured is `-`, never absent, so a column of the
//! comparison table is never shifted.

use crate::privacy;

/// The line's prefix and version. A parser keys on this; a change to the shape bumps `v`.
pub const PREFIX: &str = "wa-transcript";
pub const VERSION: u32 = 1;
/// The longest a value may be, so a long error string cannot turn into a paragraph in the log.
pub const MAX_VALUE: usize = 120;

/// One metadata line about one voice note. Built at the call site, printed once.
#[derive(Clone, Debug)]
pub struct Note {
    kind: &'static str,
    chat: String,
    id: String,
    fields: Vec<(&'static str, String)>,
}

impl Note {
    /// `kind` is the closed set `ready`, `posted`, `failed`, `expired`, `blocked`, `unsupported`;
    /// the comparison table groups on it.
    pub fn new(kind: &'static str) -> Note {
        Note { kind, chat: String::new(), id: String::new(), fields: Vec::new() }
    }

    /// The chat and the message ID: the join key the comparison table uses, as digests - the same chat
    /// is the same mark in every run, and no JID is written down.
    pub fn about(mut self, chat: &str, id: &str) -> Note {
        self.chat = chat.to_string();
        self.id = id.to_string();
        self
    }

    /// A string field (`state`, `stage`, `reason`).
    pub fn field(mut self, key: &'static str, value: &str) -> Note {
        self.fields.push((key, value.to_string()));
        self
    }

    /// A duration in milliseconds; `None` (not measured) is `-`.
    pub fn millis(self, key: &'static str, value: Option<u64>) -> Note {
        match value {
            Some(ms) => self.field(key, &ms.to_string()),
            None => self.field(key, "-"),
        }
    }

    /// A count (characters, segments, parts, edits).
    pub fn count(self, key: &'static str, value: u64) -> Note {
        self.field(key, &value.to_string())
    }

    /// A boolean, spelled the way the comparison script reads it.
    pub fn flag(self, key: &'static str, value: bool) -> Note {
        self.field(key, if value { "true" } else { "false" })
    }

    /// The log line. Always one line: values are tokenized, so no newline can survive, and the two
    /// identities are digests (`privacy::mark`), so the line cannot name a chat or a message.
    pub fn line(&self) -> String {
        let mut line = format!(
            "{PREFIX} v={VERSION} kind={} {} {}",
            token(self.kind),
            privacy::chat(&self.chat),
            privacy::id(&self.id)
        );
        for (key, value) in &self.fields {
            line.push(' ');
            line.push_str(key);
            line.push('=');
            line.push_str(&token(value));
        }
        line
    }
}

/// Everything outside the token alphabet becomes `_`, and the value is capped: a parser splits on
/// whitespace, so a value must never contain any.
fn token(value: &str) -> String {
    let mut out = String::with_capacity(value.len().min(MAX_VALUE));
    for (used, ch) in value.chars().enumerate() {
        if used >= MAX_VALUE {
            break;
        }
        if ch.is_ascii_alphanumeric() || matches!(ch, '.' | ':' | '@' | '/' | '_' | '-' | '+') {
            out.push(ch);
        } else {
            out.push('_');
        }
    }
    if out.is_empty() {
        out.push('-');
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    fn parse(line: &str) -> BTreeMap<String, String> {
        let mut fields = BTreeMap::new();
        let rest = line.strip_prefix(&format!("{PREFIX} ")).expect("the stable prefix");
        for pair in rest.split(' ') {
            let (key, value) = pair.split_once('=').expect("one '=' per field");
            assert!(fields.insert(key.into(), value.into()).is_none(), "{key} repeated");
        }
        fields
    }

    #[test]
    fn the_shape_is_the_one_the_comparison_script_parses() {
        let line = Note::new("ready")
            .about("1203630@g.us", "3EB0A1")
            .field("state", "transcribed")
            .millis("download_ms", Some(412))
            .millis("first_segment_ms", Some(1503))
            .millis("total_ms", Some(6_120))
            .count("chars", 214)
            .count("segments", 9)
            .line();
        let chat = privacy::mark("1203630@g.us");
        let id = privacy::mark("3EB0A1");
        assert_eq!(
            line,
            format!("wa-transcript v=1 kind=ready chat={chat} id={id} state=transcribed download_ms=412 first_segment_ms=1503 total_ms=6120 chars=214 segments=9")
        );
        let fields = parse(&line);
        assert_eq!(fields["v"], "1");
        assert_eq!(fields["kind"], "ready");
        assert_eq!(fields["chars"], "214");
        assert_eq!(fields["chat"], chat, "the chat is a digest, not the JID");
        assert_eq!(fields["id"], id);
        // Nothing a log line may not carry: no JID, no phone number, no message id.
        assert!(!line.contains('@'));
        assert!(!line.contains("1203630"));
        assert!(!line.contains("3EB0A1"));
    }

    #[test]
    fn an_absent_identity_is_a_dash_and_not_an_empty_field() {
        let fields = parse(&Note::new("shadow").line());
        assert_eq!(fields["chat"], "-");
        assert_eq!(fields["id"], "-");
    }

    #[test]
    fn an_unmeasured_timing_is_a_dash_so_columns_never_shift() {
        let line = Note::new("failed").about("1@s.whatsapp.net", "x").millis("first_segment_ms", None).millis("total_ms", None).field("stage", "download").line();
        let fields = parse(&line);
        assert_eq!(fields["first_segment_ms"], "-");
        assert_eq!(fields["total_ms"], "-");
        assert_eq!(fields["stage"], "download");
    }

    #[test]
    fn a_value_with_spaces_or_newlines_is_still_one_token() {
        // An error string is a reason, not a message: it must never split the line into two
        // fields, nor smuggle a newline into the log.
        let line = Note::new("failed").about("1@s.whatsapp.net", "x").field("reason", "worker said: no dice\nsecond line").line();
        assert!(!line.contains('\n'));
        assert_eq!(line.split(' ').count(), 6, "v, kind, chat, id, reason: five keys, six tokens: {line}");
        let fields = parse(&line);
        assert_eq!(fields["reason"], "worker_said:_no_dice_second_line");
    }

    #[test]
    fn a_long_value_is_capped() {
        let long = "e".repeat(500);
        let line = Note::new("failed").about("c@x", "i").field("reason", &long).line();
        let fields = parse(&line);
        assert_eq!(fields["reason"].len(), MAX_VALUE);
    }

    #[test]
    fn an_empty_value_becomes_a_dash_and_not_an_empty_field() {
        let line = Note::new("blocked").about("", "").field("reason", "").line();
        let fields = parse(&line);
        assert_eq!(fields["chat"], "-");
        assert_eq!(fields["id"], "-");
        assert_eq!(fields["reason"], "-");
    }
}
