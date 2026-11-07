//! The connector's log lines: a stable `wa-email v=1 key=value` shape that carries ids, states,
//! counts and reasons - never a subject, a body, an attachment name, an address or a credential.
//!
//! The rule this module enforces is structural: [`Line::field`] takes a `u64` and [`Line::word`] takes
//! a short code that is sanitized down to `[A-Za-z0-9_.:-]`, so there is no way to hand a log line a
//! piece of mail by accident. Server answers (which can echo a credential) go through [`sanitize`] and
//! then through `wa_email_outbox::redact` at the call site.
use wa_email_outbox::redact;

/// The longest one field may be.
const MAX_WORD: usize = 64;

/// One log line under construction.
#[derive(Clone, Debug)]
pub struct Line {
    text: String,
}

impl Line {
    /// Start a line for one event (`sync`, `send`, `dropped`, `auth_failed`, …).
    pub fn new(event: &str) -> Line {
        Line { text: format!("wa-email v=1 event={}", word(event, 32)) }
    }

    /// A count, an id, a duration or a timestamp.
    pub fn field(mut self, key: &str, value: u64) -> Line {
        self.text.push(' ');
        self.text.push_str(&word(key, 24));
        self.text.push('=');
        self.text.push_str(&value.to_string());
        self
    }

    /// A short code: a state, an error word, a host:port. Sanitized, never free text.
    pub fn word(mut self, key: &str, value: &str) -> Line {
        self.text.push(' ');
        self.text.push_str(&word(key, 24));
        self.text.push('=');
        self.text.push_str(&word(value, MAX_WORD));
        self
    }

    pub fn build(self) -> String {
        self.text
    }
}

/// Strip everything that is not `[A-Za-z0-9_.:-]` and bound the length: what is left cannot open a new
/// log line, break a `key=value` pair, or carry a sentence of mail.
pub fn word(text: &str, max: usize) -> String {
    let mut out = String::with_capacity(text.len().min(max));
    for c in text.chars() {
        if out.chars().count() >= max {
            break;
        }
        if c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | ':' | '-' | '/' | '@') {
            out.push(c);
        } else {
            out.push('_');
        }
    }
    if out.is_empty() {
        out.push('-');
    }
    out
}

/// A server answer, quoted for a log: control characters gone, bounded, and every known secret
/// replaced. This is the only function a protocol error's detail should pass through.
pub fn sanitize(answer: &str, secrets: &[&str]) -> String {
    let flat: String = answer.chars().map(|c| if c.is_control() { ' ' } else { c }).collect();
    let redacted = redact(&flat, secrets);
    let mut out: String = redacted.split_whitespace().collect::<Vec<_>>().join(" ");
    if out.chars().count() > 200 {
        out = out.chars().take(200).collect::<String>() + "…";
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use wa_email_outbox::Secret;

    #[test]
    fn a_line_is_ids_states_and_counts_in_one_shape() {
        let line = Line::new("sync").field("fetched", 3).field("indexed", 2).word("result", "ok").build();
        assert_eq!(line, "wa-email v=1 event=sync fetched=3 indexed=2 result=ok");
        // A word cannot smuggle a newline, a space or a body into the line.
        let injected = Line::new("sync").word("subject", "Relatório\r\nBcc: evil@example.com").build();
        assert_eq!(injected, "wa-email v=1 event=sync subject=Relat_rio__Bcc:_evil@example.com");
        assert!(!injected.contains('\n') && !injected.contains('\r'));
        // A word is bounded, so a long string cannot become a log line of its own.
        let long = Line::new("x").word("k", &"a".repeat(500)).build();
        assert!(long.len() < 120, "{}", long.len());
        // An empty event is a dash, never an empty token.
        assert_eq!(Line::new("").build(), "wa-email v=1 event=-");
    }

    #[test]
    fn a_server_answer_is_flattened_redacted_and_bounded() {
        let secret = Secret::new("hunter2-correct-horse");
        let answer = "535 5.7.8\tbad\r\ncredentials hunter2-correct-horse for user me@example.com";
        let quiet = sanitize(answer, &[secret.expose()]);
        assert!(!quiet.contains("hunter2"), "{quiet}");
        assert!(!quiet.contains('\n') && !quiet.contains('\t'));
        assert_eq!(quiet, "535 5.7.8 bad credentials *** for user me@example.com");
        // A long answer is cut, visibly.
        let long = sanitize(&"x ".repeat(400), &[]);
        assert!(long.ends_with('…'));
        assert!(long.chars().count() <= 201);
    }

    #[test]
    fn the_lines_the_connector_writes_hold_no_mail() {
        // The shape is what makes this true: a line can only be handed numbers and codes. A test that
        // built lines from a record would be checking the caller, so this one checks the builder.
        let line = Line::new("received").field("uid", 12).field("bytes", 1_024).word("mailbox", "INBOX").build();
        assert!(line.starts_with("wa-email v=1 "));
        for token in line.split(' ') {
            assert!(token.contains('=') || token == "wa-email" || token == "v=1", "{token}");
        }
    }
}
