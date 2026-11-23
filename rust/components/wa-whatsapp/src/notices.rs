//! Deletion notices for source mutations (revokes and edits).
//!
//! WHAT THIS REPLACED, AND WHY. This module was `holds.rs`: a revoke or an edit the component could not
//! attribute to a stored message put the whole CHAT on a hold, and every post into that chat was refused
//! for good (`posting_held_chat`), with no way for the operator to lift it. On 23/11 the owner ended that
//! design in one line: *"we never should get hold from a chat"*. A deletion is a fact about ONE MESSAGE:
//!
//!   * the message it names keeps its content, its transcript and its OCR text, and gains `deleted`;
//!   * an automatic reply to it that has not been posted yet is skipped - one reply, by message id;
//!   * a notice that names no message this store holds leaves a TOMBSTONE by message id, so the message is
//!     flagged deleted the moment it arrives (a re-delivery, a history sync, a backfill);
//!   * nothing about a notice touches another message of the chat, and an explicit send the owner asks for
//!     is never refused because of one.
//!
//! What is left here is the part that needs no store: the notice itself, the identity rule that says
//! whether two spellings are the same chat, the tombstone's shape (the index writes and applies it,
//! `index::key_tombstone`), and the LEDGER - the two counters the health line prints, so "this node could
//! not match a deletion notice" stays a number a reader can see instead of a chat silently blocked.

/// Message IDs longer than this are malformed, not a target (Go: 256).
pub const MAX_ID: usize = 256;

/// One revoke, edit or owner clear observed on the wire.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Notice {
    /// The chat the notice arrived in, as the envelope spelled it.
    pub chat: String,
    /// `revoke` or `edit`.
    pub kind: String,
    /// The message ID the notice's key names (`""` = untargeted: nothing narrower than a chat is named).
    pub target: String,
    pub sender: String,
    /// The other address of the same user (PN<->LID), when the envelope carried it.
    pub sender_alt: String,
    pub own: bool,
    /// The owner cleared/deleted the chat (an SDK event, not a message key).
    pub owner: bool,
    /// The notice's own key names this chat, or an address of the same chat.
    pub scope_proven: bool,
    /// When this node saw the notice, Unix ms.
    pub at_ms: i64,
}

impl Notice {
    pub fn revoke(chat: &str, target: &str) -> Self {
        Notice {
            chat: chat.into(),
            kind: "revoke".into(),
            target: target.into(),
            sender: String::new(),
            sender_alt: String::new(),
            own: false,
            owner: false,
            scope_proven: true,
            at_ms: 0,
        }
    }

    pub fn edit(chat: &str, target: &str) -> Self {
        Notice { kind: "edit".into(), ..Notice::revoke(chat, target) }
    }

    /// Does this notice name one message? A notice that does not can only be counted: there is nothing
    /// narrower than "somewhere in this chat" to act on, and acting on the chat is what was removed.
    pub fn targeted(&self) -> bool {
        !self.target.is_empty() && self.target.chars().count() <= MAX_ID
    }
}

/// A bare user JID: no device part, and one of the two user servers (Go: `validUserID`). The store's
/// alias rows are only ever written for an address this accepts, so a learned LID<->PN join always names
/// a person and never a group or a status address.
pub fn valid_user(jid: &str) -> bool {
    let Some((user, server)) = jid.split_once('@') else { return false };
    !user.is_empty() && !user.contains(':') && user.chars().all(|c| c.is_ascii_digit()) && (server == "s.whatsapp.net" || server == "lid")
}

/// Is this the same chat? A notice's key may carry a device part or the other address of the same user
/// (`7210:12@lid` vs `7210@lid`): the comparison is on the user and server only. This is a *spelling*
/// rule; the store's `ix/al/` rows are what prove that a LID and a phone number are the same person, and
/// the index matches by message id across every form for exactly that reason.
pub fn same_chat(a: &str, b: &str) -> bool {
    fn bare(jid: &str) -> String {
        let (user, server) = jid.split_once('@').unwrap_or((jid, ""));
        format!("{}@{server}", user.split(':').next().unwrap_or(user))
    }
    !a.is_empty() && bare(a) == bare(b)
}

/// A message this node was told is deleted and does not hold (yet). The index writes it under
/// `ix/tomb/<id>` and applies it once, when the message arrives under any chat spelling.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Tombstone {
    /// The chat the notice named, as the wire spelled it (the message may arrive under another one).
    pub chat: String,
    /// `revoke` or `edit`.
    pub kind: String,
    /// When the notice was seen, Unix ms: the deletion's own date, which is what a read reports.
    pub at_ms: i64,
    /// Who deleted it, when the notice carried a sender.
    pub by: String,
}

/// The two counters that make an unmatched notice visible, and the time of the last of each.
///
/// Persisted (kv key `notices`) so a restart keeps the numbers: a counter that resets on every restart
/// cannot be the thing that says whether the node is failing to match, and this is the defect counter the
/// removal of chat holds must not hide (`docs/FEATURES-HEALTH.md`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct Ledger {
    pub matched: u64,
    pub unmatched: u64,
    /// The last notice of either kind (Unix ms, 0 = never).
    pub last_ms: i64,
    /// The last notice that named no message this store holds (Unix ms, 0 = never).
    pub last_unmatched_ms: i64,
}

impl Ledger {
    pub fn new() -> Self {
        Ledger::default()
    }

    /// One notice that found its message.
    pub fn matched(&mut self, at_ms: i64) {
        self.matched = self.matched.saturating_add(1);
        self.last_ms = at_ms;
    }

    /// One notice that named no message this store holds. It left a tombstone, and it is counted: the
    /// count is the defect signal (a deletion notice the node could not match), never a block.
    pub fn unmatched(&mut self, at_ms: i64) {
        self.unmatched = self.unmatched.saturating_add(1);
        self.last_ms = at_ms;
        self.last_unmatched_ms = at_ms;
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string(self).unwrap_or_else(|_| "{}".into())
    }

    /// Read back what a previous run left. A value this build cannot read is an empty ledger, never a
    /// guess: an unreadable ledger must not look like "no notice was ever unmatched".
    pub fn from_json(text: &str) -> Self {
        serde_json::from_str(text).unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DM: &str = "5511999@s.whatsapp.net";
    const LID: &str = "7210397@lid";

    #[test]
    fn a_notice_names_one_message_or_nothing() {
        assert!(Notice::revoke(DM, "MSG1").targeted());
        assert!(!Notice::revoke(DM, "").targeted(), "an untargeted notice names no message");
        assert!(!Notice::revoke(DM, &"x".repeat(MAX_ID + 1)).targeted(), "a malformed id is not a target");
        let edit = Notice::edit(DM, "MSG1");
        assert_eq!(edit.kind, "edit");
        assert_eq!(edit.target, "MSG1");
        assert!(!edit.owner && edit.scope_proven);
    }

    #[test]
    fn the_same_chat_under_another_spelling_is_the_same_chat() {
        assert!(same_chat(LID, "7210397:12@lid"), "a device part is not another chat");
        assert!(same_chat(DM, DM));
        assert!(!same_chat(DM, LID), "a LID and a phone number are joined by the store's alias rows, not by this rule");
        assert!(!same_chat("", ""));
    }

    #[test]
    fn a_matched_notice_and_an_unmatched_one_are_counted_apart() {
        let mut ledger = Ledger::new();
        ledger.matched(1_000);
        ledger.unmatched(2_000);
        assert_eq!(ledger, Ledger { matched: 1, unmatched: 1, last_ms: 2_000, last_unmatched_ms: 2_000 });
        // An unmatched notice does not move the "last matched" number: the two are different facts.
        ledger.matched(3_000);
        assert_eq!((ledger.unmatched, ledger.last_unmatched_ms), (1, 2_000));
        assert_eq!((ledger.matched, ledger.last_ms), (2, 3_000));
    }

    #[test]
    fn a_restart_keeps_the_counters() {
        let mut ledger = Ledger::new();
        ledger.matched(1_000);
        ledger.unmatched(2_000);
        assert_eq!(Ledger::from_json(&ledger.to_json()), ledger);
        // A value this build cannot read is an empty ledger, not an invented one.
        assert_eq!(Ledger::from_json("not json"), Ledger::new());
        assert_eq!(Ledger::from_json(""), Ledger::new());
    }
}
