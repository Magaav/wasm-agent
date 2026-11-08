//! What a log line may say about who: a hashed identity, never a JID.
//!
//! The service log is read by operators, pasted into issue reports and kept after the component that
//! wrote it is gone, so a line may not carry a phone number, a group id or a sender. This is the same
//! rule the node audit trail follows (`wa-grant-policy`'s `TargetMode::Digest`): `sha256:` plus the
//! first 16 bytes of the digest, 32 hex characters. A digested id is still a join key - the same chat
//! is the same mark on every line, in every run and on every node - so "this chat" can be followed
//! through a log without the log naming the chat.
//!
//! Two shapes, because both happen at the call sites and only one of them may be spelled by hand:
//!
//! * [`chat`], [`sender`], [`id`] render a whole `key=value` field (`chat=sha256:…`), so the line
//!   interpolates a field and never a bare value;
//! * [`mark`] is the value alone, for the telemetry line, whose fields are built by
//!   [`crate::telemetry`] rather than at the call site.
//!
//! `tests::no_component_log_line_spells_a_chat_or_an_id_itself` reads this crate's own log-bearing
//! sources and fails on a line that spells `chat=`, `sender=` or `id=` with an interpolation, which is
//! what keeps the next log line honest without anyone having to remember this module.
use sha2::{Digest, Sha256};

/// First 16 bytes of SHA-256, hex: exactly the digest `wa-grant-policy::audit::digest_hex` writes, so a
/// mark in a component log and a mark in the audit trail name the same chat the same way. (The
/// component cannot depend on that crate - it is a node-side library - so the convention is pinned by
/// the test below instead of shared by a call.)
pub fn digest_hex(value: &str) -> String {
    let digest = Sha256::digest(value.as_bytes());
    let mut out = String::with_capacity(32);
    for byte in &digest[..16] {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}

/// `sha256:<32 hex>` for an identity, or `-` for an id nobody gave (the spelling an empty telemetry
/// field uses, so a column never shifts and an absent id is visibly absent).
pub fn mark(value: &str) -> String {
    if value.is_empty() {
        return "-".to_string();
    }
    format!("sha256:{}", digest_hex(value))
}

/// The `chat=` field of a log line.
pub fn chat(chat: &str) -> String {
    format!("chat={}", mark(chat))
}

/// The `sender=` field of a log line.
pub fn sender(sender: &str) -> String {
    format!("sender={}", mark(sender))
}

/// The `id=` field of a log line: a message, event or media id.
pub fn id(id: &str) -> String {
    format!("id={}", mark(id))
}

/// `chat=… id=…` as one field pair, because most lines carry both and a missing one is a bug.
pub fn at(chat_value: &str, id_value: &str) -> String {
    format!("{} {}", chat(chat_value), id(id_value))
}

#[cfg(test)]
mod tests {
    use super::*;

    const CHAT: &str = "5511999999999@s.whatsapp.net";
    const GROUP: &str = "120363000000000001@g.us";
    const ID: &str = "3EB0A1B2C3D4E5F6";

    #[test]
    fn the_mark_is_the_audit_trail_s_digest() {
        // The digest wa-grant-policy's own test pins for the empty target: one convention, two crates.
        assert_eq!(digest_hex(""), "e3b0c44298fc1c149afbf4c8996fb924");
        assert_eq!(mark(""), "-", "an id nobody gave is visibly absent");
        let mark_of_chat = mark(CHAT);
        assert_eq!(mark_of_chat.len(), "sha256:".len() + 32);
        assert!(mark_of_chat.starts_with("sha256:"));
        assert!(mark_of_chat["sha256:".len()..].chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
        // Stable across calls and runs (nothing random, nothing salted), and distinct per chat.
        assert_eq!(mark(CHAT), mark_of_chat);
        assert_ne!(mark(CHAT), mark(GROUP));
    }

    #[test]
    fn a_marked_field_carries_no_jid_no_number_and_no_message_id() {
        let chat = chat(CHAT);
        assert_eq!(chat, format!("chat=sha256:{}", digest_hex(CHAT)));
        for text in [&chat, &sender(CHAT), &id(ID)] {
            assert!(!text.contains('@'), "no JID survives: {text}");
            assert!(!text.contains("5511999999999"), "no phone number survives: {text}");
            assert!(!text.contains(GROUP), "no group id survives: {text}");
            assert!(!text.contains(ID), "no message id survives: {text}");
            assert_eq!(text.split(' ').count(), 1, "one field, one token: {text}");
        }
        // The pair is two fields, in the order the lines promise, and neither names an identity.
        let at = at(GROUP, ID);
        assert_eq!(at, format!("chat={} id={}", mark(GROUP), mark(ID)));
        assert!(!at.contains('@') && !at.contains(GROUP) && !at.contains(ID), "{at}");
    }

    /// Every file of this crate that prints a line, read from disk at compile time. A log line may
    /// interpolate a field rendered by this module (`privacy::chat(&x)`, `privacy::at(&chat, &id)`) or
    /// a count/word, but never the identity itself.
    fn log_sources() -> [(&'static str, &'static str); 3] {
        [
            ("guest.rs", include_str!("guest.rs")),
            ("ocr.rs", include_str!("ocr.rs")),
            ("telemetry.rs", include_str!("telemetry.rs")),
        ]
    }

    #[test]
    fn no_component_log_line_spells_a_chat_or_an_id_itself() {
        // The patterns that put a raw identity into a line: `chat={chat}` / `chat={}` with the value
        // passed separately, and the same for a sender and a message id. `privacy::at()` is how a line
        // says both, so a hit here means someone went around it.
        let banned = ["chat={", "sender={", "id={"];
        let mut offenders = Vec::new();
        for (name, full) in log_sources() {
            // Tests are cut off first: a test spells the shape it asserts on.
            let text = full.split("#[cfg(test)]").next().unwrap_or(full);
            for (number, line) in text.lines().enumerate() {
                // Comments (and doc comments) describe the rule; only code is scanned.
                let code = line.split("//").next().unwrap_or("");
                if banned.iter().any(|pattern| code.contains(pattern)) {
                    offenders.push(format!("{name}:{}: {}", number + 1, code.trim()));
                }
            }
        }
        assert!(offenders.is_empty(), "a log line prints an identity instead of its mark:\n{}", offenders.join("\n"));
    }
}
