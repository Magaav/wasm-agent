//! Chat holds and message fences for source mutations (revokes and edits).
//!
//! Ported from the Go connector (`connectors/whatsapp/reliability.go` `mutate`,
//! `mutation_mapping.go` `mutationProof`, `audio_queue.go` `computeFence`/`postingHeld`,
//! `hold_reprove.go` `reproveHolds`) so the component no longer needs a hand-maintained
//! `held_chats` list to stay safe: the hold is derived from what the wire actually said.
//!
//! Two strengths, because they allow different work:
//!   * a **posting-only** hold (`unproven_mutation_chat_hold`): a revoke/edit named an exact message
//!     ID but we cannot prove the mutation is about this chat (typically a DM journaled under its
//!     `@lid` while the key carried the phone number). That ID is fenced in every chat of the
//!     account, and the chat may still be transcribed: transcription is a local derive with no
//!     external effect, and losing it is what made an unreadable audio permanent;
//!   * a **compute** hold (`untargeted_mutation_chat_hold`, `owner_chat_clear_hold`): nothing
//!     narrower than the whole chat is provable, so the chat is not transcribed either.
//!
//! A proven mutation is not a hold at all: it fences the exact IDs it named (in that chat), as the
//! Go connector's `source_blocks` do.
//!
//! Holds strengthen, never weaken (a later targeted revoke cannot lower an untargeted hold). A
//! posting-only hold can be *re-proved* from the journal (`reprove`): when every unproven mutation
//! recorded for the chat names a message of that same chat by the same author, the mutation is
//! exactly that message's revoke, the hold is replaced by exact fences, and the chat's posting
//! resumes. Holds and fences are pure state, snapshotted to kv by the caller.
use std::collections::{BTreeMap, BTreeSet};

/// Posting-only hold: posting blocked, transcription allowed.
pub const POSTING_ONLY: &str = "unproven_mutation_chat_hold";
/// Compute hold: the chat is not transcribed either.
pub const UNTARGETED: &str = "untargeted_mutation_chat_hold";
/// Compute hold created by the owner clearing or deleting the chat.
pub const OWNER: &str = "owner_chat_clear_hold";
/// Message IDs longer than this are malformed, not a target (Go: 256).
pub const MAX_ID: usize = 256;

/// Who wrote a message, as far as the store knows it.
#[derive(Clone, Debug, Default, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Author {
    pub sender: String,
    /// The other address of the same user (PN<->LID), when the envelope carried it.
    pub alt: String,
    pub own: bool,
    /// Two observations disagreed about this author: nothing about them is provable.
    pub ambiguous: bool,
}

impl Author {
    pub fn new(sender: &str, alt: &str, own: bool) -> Self {
        Author { sender: sender.into(), alt: alt.into(), own, ambiguous: false }
    }
}

/// One revoke or edit observed on the wire.
#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Mutation {
    pub chat: String,
    /// `revoke` or `edit`.
    pub kind: String,
    /// The message ID the mutation's key names (`""` = untargeted).
    pub target: String,
    pub sender: String,
    pub sender_alt: String,
    pub own: bool,
    /// The owner cleared/deleted the chat (an SDK event, not a key): only the whole chat is provable.
    pub owner: bool,
    /// The mutation's envelope names this chat, or a proven alias of it.
    pub scope_proven: bool,
}

impl Mutation {
    pub fn revoke(chat: &str, target: &str) -> Self {
        Mutation {
            chat: chat.into(),
            kind: "revoke".into(),
            target: target.into(),
            sender: String::new(),
            sender_alt: String::new(),
            own: false,
            owner: false,
            scope_proven: true,
        }
    }
}

/// What the store knows about the message a mutation names.
pub type Known<'a> = Option<&'a Author>;

/// What one mutation decided.
#[derive(Clone, Debug, PartialEq)]
pub struct Verdict {
    pub verified: bool,
    /// Why: `stored_exact`, `owner_sdk_event`, `target_id_missing`, `scope_unproven`,
    /// `target_missing`, `ambiguous_author`, `author_mismatch`, ... (metadata only).
    pub proof: &'static str,
    /// IDs fenced in every chat (unproven target: a DM's PN/LID alias may differ from this chat).
    pub fence_everywhere: Vec<String>,
    /// IDs fenced in this chat only (a proven revoke/edit of a message here).
    pub fence_here: Vec<String>,
    /// The hold this mutation put on the chat (or strengthened it to), if any.
    pub hold: Option<&'static str>,
}

/// A bare user JID: no device part, and one of the two user servers (Go: `validUserID`).
pub fn valid_user(jid: &str) -> bool {
    let Some((user, server)) = jid.split_once('@') else { return false };
    !user.is_empty() && !user.contains(':') && user.chars().all(|c| c.is_ascii_digit()) && (server == "s.whatsapp.net" || server == "lid")
}

/// The same person under another address (`5511...@s.whatsapp.net` vs the same user's `@lid`).
pub fn author_equivalent(a: &str, alt_a: &str, b: &str, alt_b: &str) -> bool {
    if !valid_user(a) || !valid_user(b) {
        return false;
    }
    a == b || (valid_user(alt_a) && alt_a == b) || (valid_user(alt_b) && alt_b == a)
}

#[derive(Clone, Debug, Default, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Holds {
    /// chat -> reason. A chat appears once, with its strongest reason.
    held: BTreeMap<String, String>,
    /// Message IDs fenced in every chat (an unproven target).
    fence_everywhere: BTreeSet<String>,
    /// chat -> message IDs fenced in that chat (a proven revoke/edit).
    fence_here: BTreeMap<String, BTreeSet<String>>,
    /// chat -> the unproven mutations recorded for it, oldest first (the re-prove evidence).
    evidence: BTreeMap<String, Vec<Mutation>>,
}

impl Holds {
    pub fn new() -> Self {
        Holds::default()
    }

    /// Apply one mutation. `known` is what the store says about the target message's author (only
    /// the store can prove authorship; the wire never can on its own).
    pub fn apply(&mut self, m: &Mutation, known: Known<'_>) -> Verdict {
        let (verified, proof) = self.prove(m, known);
        let targeted = !m.target.is_empty() && m.target.chars().count() <= MAX_ID;
        let mut verdict = Verdict { verified, proof, fence_everywhere: Vec::new(), fence_here: Vec::new(), hold: None };
        if verified {
            if targeted {
                self.fence_here.entry(m.chat.clone()).or_default().insert(m.target.clone());
                verdict.fence_here.push(m.target.clone());
            }
            return verdict;
        }
        // Record the evidence first: a restart keeps it, and `reprove` needs it.
        let evidence = self.evidence.entry(m.chat.clone()).or_default();
        if evidence.len() < 32 {
            evidence.push(m.clone());
        }
        let reason = if m.owner && m.target.is_empty() {
            OWNER
        } else if targeted && !m.owner {
            self.fence_everywhere.insert(m.target.clone());
            verdict.fence_everywhere.push(m.target.clone());
            POSTING_ONLY
        } else {
            UNTARGETED
        };
        verdict.hold = Some(self.hold(&m.chat, reason));
        verdict
    }

    /// Is the chat held at all (posting blocked)? Also true for a compute hold.
    pub fn posting_held(&self, chat: &str) -> bool {
        self.held.contains_key(chat)
    }

    /// Is the chat held for transcription too?
    pub fn compute_held(&self, chat: &str) -> bool {
        self.held.get(chat).is_some_and(|reason| reason != POSTING_ONLY)
    }

    pub fn reason(&self, chat: &str) -> Option<&str> {
        self.held.get(chat).map(String::as_str)
    }

    /// Is this message ID fenced in this chat (a proven revoke here, or an unproven target
    /// anywhere)? A fenced source is never transcribed or posted.
    pub fn blocked(&self, chat: &str, id: &str) -> bool {
        self.fence_everywhere.contains(id) || self.fence_here.get(chat).is_some_and(|ids| ids.contains(id))
    }

    /// The hold for `chat` after a mutation that calls for `reason`; holds strengthen, never weaken.
    fn hold(&mut self, chat: &str, reason: &'static str) -> &'static str {
        let existing = self.held.get(chat).cloned();
        match existing.as_deref() {
            Some(current) if current == reason => reason,
            // A compute hold is already stronger than anything else: it stays as it is.
            Some(UNTARGETED) => UNTARGETED,
            Some(OWNER) => OWNER,
            // Nothing (or a posting-only hold) becomes this reason.
            _ => {
                self.held.insert(chat.to_string(), reason.to_string());
                reason
            }
        }
    }

    /// Go's `mutationProof`: can the store prove that this mutation is about the message it names?
    fn prove(&self, m: &Mutation, known: Known<'_>) -> (bool, &'static str) {
        if m.owner && m.target.is_empty() {
            return (false, "owner_chat_operation");
        }
        if m.target.is_empty() {
            return (false, "target_id_missing");
        }
        if m.target.chars().count() > MAX_ID {
            return (false, "target_id_invalid");
        }
        if m.kind != "revoke" && m.kind != "edit" {
            return (false, "not_a_mutation");
        }
        if !m.scope_proven {
            return (false, "scope_unproven");
        }
        if m.owner {
            return (true, "owner_sdk_event");
        }
        let Some(known) = known else { return (false, "target_missing") };
        if known.ambiguous {
            return (false, "ambiguous_author");
        }
        if (m.own && known.own) || (!known.own && !m.own && author_equivalent(&known.sender, &known.alt, &m.sender, &m.sender_alt)) {
            return (true, "stored_exact");
        }
        (false, "author_mismatch")
    }

    /// Go's `reproveHolds` for one chat: replace a posting-only hold by exact fences when the
    /// evidence recorded for the chat proves every one of its mutations. `look` is the store's
    /// author lookup for (chat, id). Returns how many holds/targets it settled.
    pub fn reprove(&mut self, chat: &str, look: impl Fn(&str) -> Option<Author>) -> Reproved {
        let mut report = Reproved::default();
        if self.held.get(chat).map(String::as_str) != Some(POSTING_ONLY) {
            report.skipped = Some("other_hold");
            return report;
        }
        let Some(evidence) = self.evidence.get(chat).cloned() else {
            report.skipped = Some("legacy_hold_no_evidence");
            return report;
        };
        if evidence.is_empty() {
            report.skipped = Some("legacy_hold_no_evidence");
            return report;
        }
        for m in &evidence {
            let targeted = !m.target.is_empty() && m.target.chars().count() <= MAX_ID && !m.owner;
            if !targeted {
                report.skipped = Some("untargeted_mutation");
                return report;
            }
            let Some(known) = look(&m.target) else {
                report.skipped = Some("target_not_in_chat");
                return report;
            };
            if known.ambiguous || !((m.own && known.own) || (!known.own && !m.own && author_equivalent(&known.sender, &known.alt, &m.sender, &m.sender_alt))) {
                report.skipped = Some("author_unproven");
                return report;
            }
        }
        for m in &evidence {
            self.fence_here.entry(chat.to_string()).or_default().insert(m.target.clone());
            report.fenced += 1;
        }
        self.held.remove(chat);
        self.evidence.remove(chat);
        report.reproved = 1;
        report
    }

    /// Persist to kv (one JSON value).
    pub fn to_json(&self) -> String {
        serde_json::to_string(self).unwrap_or_else(|_| "{\"held\":{},\"fence_everywhere\":[],\"fence_here\":{},\"evidence\":{}}".into())
    }

    pub fn from_json(text: &str) -> Self {
        serde_json::from_str(text).unwrap_or_default()
    }

    pub fn held_chats(&self) -> usize {
        self.held.len()
    }

    /// Every held chat with its reason (for the re-proof pass at start, and the log line).
    pub fn held_reasons(&self) -> Vec<(String, String)> {
        self.held.iter().map(|(chat, reason)| (chat.clone(), reason.clone())).collect()
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Reproved {
    /// 1 when a hold was replaced by exact fences, 0 otherwise.
    pub reproved: u32,
    /// Message IDs fenced by the re-proof.
    pub fenced: u32,
    /// Why nothing changed (metadata only).
    pub skipped: Option<&'static str>,
}

#[cfg(test)]
mod tests {
    use super::*;

    const DM: &str = "5511999@s.whatsapp.net";
    const LID: &str = "7210397@lid";

    fn revoke_in(chat: &str, target: &str, sender: &str) -> Mutation {
        Mutation { sender: sender.into(), ..Mutation::revoke(chat, target) }
    }

    fn author(sender: &str) -> Author {
        Author::new(sender, "", false)
    }

    #[test]
    fn a_proven_revoke_fences_that_message_only_and_holds_nothing() {
        let mut holds = Holds::new();
        let author = author(DM);
        let m = revoke_in(DM, "MSG1", DM);
        let v = holds.apply(&m, Some(&author));
        assert!(v.verified && v.proof == "stored_exact");
        assert_eq!(v.fence_here, vec!["MSG1".to_string()]);
        assert!(v.fence_everywhere.is_empty() && v.hold.is_none());
        assert!(holds.blocked(DM, "MSG1"));
        assert!(!holds.blocked(DM, "MSG2"), "the rest of the chat is untouched");
        assert!(!holds.posting_held(DM) && !holds.compute_held(DM));
    }

    #[test]
    fn an_unproven_revoke_holds_posting_only_and_fences_the_target_everywhere() {
        let mut holds = Holds::new();
        // The key names the PN while the DM is journaled under its LID: not provable here.
        let m = revoke_in(LID, "MSG1", DM);
        let v = holds.apply(&m, None);
        assert!(!v.verified && v.proof == "target_missing");
        assert_eq!(v.fence_everywhere, vec!["MSG1".to_string()]);
        assert_eq!(v.hold, Some(POSTING_ONLY));
        assert!(holds.posting_held(LID));
        assert!(!holds.compute_held(LID), "transcription continues: a local derive, no external effect");
        assert!(holds.blocked(DM, "MSG1"), "the target is fenced in every chat of the account");
        assert!(!holds.blocked(DM, "MSG2"));
    }

    #[test]
    fn an_untargeted_or_owner_mutation_holds_the_whole_chat() {
        let mut holds = Holds::new();
        let mut untargeted = Mutation::revoke(DM, "");
        untargeted.kind = "revoke".into();
        let v = holds.apply(&untargeted, None);
        assert_eq!(v.proof, "target_id_missing");
        assert_eq!(v.hold, Some(UNTARGETED));
        assert!(holds.compute_held(DM), "nothing narrower is provable: no transcription either");

        let group = "1203@g.us";
        let mut owner = Mutation::revoke(group, "");
        owner.owner = true;
        let v = holds.apply(&owner, None);
        assert_eq!(v.hold, Some(OWNER));
        assert!(holds.compute_held(group));
        assert!(!holds.compute_held("9999@s.whatsapp.net"), "another chat is unaffected");
        assert!(!holds.compute_held(LID), "another chat is unaffected");
    }

    #[test]
    fn a_mutation_whose_scope_is_not_proven_fences_nothing_narrower_than_the_chat() {
        let mut holds = Holds::new();
        let mut m = revoke_in(DM, "MSG1", DM);
        m.scope_proven = false;
        let v = holds.apply(&m, Some(&author(DM)));
        assert_eq!(v.proof, "scope_unproven");
        assert!(v.fence_here.is_empty());
        assert_eq!(v.hold, Some(POSTING_ONLY), "the target still gets fenced everywhere");
        assert!(holds.blocked(DM, "MSG1"));
    }

    #[test]
    fn holds_strengthen_and_never_weaken() {
        let mut holds = Holds::new();
        assert_eq!(holds.apply(&revoke_in(LID, "A", DM), None).hold, Some(POSTING_ONLY));
        // A later, broader mutation strengthens the hold.
        let mut untargeted = Mutation::revoke(LID, "");
        untargeted.kind = "edit".into();
        assert_eq!(holds.apply(&untargeted, None).hold, Some(UNTARGETED));
        // A later targeted revoke cannot weaken it back to posting-only.
        assert_eq!(holds.apply(&revoke_in(LID, "B", DM), None).hold, Some(UNTARGETED));
        assert!(holds.compute_held(LID));
        assert!(holds.blocked(LID, "B"));
    }

    #[test]
    fn an_owner_hold_is_not_weakened_by_an_untargeted_one() {
        let mut holds = Holds::new();
        let mut owner = Mutation::revoke(DM, "");
        owner.owner = true;
        holds.apply(&owner, None);
        assert_eq!(holds.reason(DM), Some(OWNER));
        let mut untargeted = Mutation::revoke(DM, "");
        untargeted.kind = "delete".into();
        holds.apply(&untargeted, None);
        assert_eq!(holds.reason(DM), Some(OWNER));
    }

    #[test]
    fn the_alias_of_the_same_user_proves_authorship() {
        let mut holds = Holds::new();
        // Journaled under the LID, revoked from the PN address: same person, so provable.
        let known = Author::new(LID, DM, false);
        let v = holds.apply(&revoke_in(LID, "MSG1", DM), Some(&known));
        assert!(v.verified && v.proof == "stored_exact");
        // Two different people: not provable.
        let mut holds = Holds::new();
        let v = holds.apply(&revoke_in(LID, "MSG2", "5511888@s.whatsapp.net"), Some(&known));
        assert!(!v.verified && v.proof == "author_mismatch");
    }

    #[test]
    fn an_ambiguous_author_proves_nothing() {
        let mut holds = Holds::new();
        let mut known = Author::new(DM, "", false);
        known.ambiguous = true;
        let v = holds.apply(&revoke_in(DM, "MSG1", DM), Some(&known));
        assert!(!v.verified && v.proof == "ambiguous_author");
    }

    #[test]
    fn the_owner_own_revoke_needs_no_author() {
        let mut holds = Holds::new();
        let mut m = revoke_in(DM, "MSG1", "");
        m.owner = true;
        m.own = true;
        let v = holds.apply(&m, None);
        assert!(v.verified && v.proof == "owner_sdk_event");
        assert_eq!(v.fence_here, vec!["MSG1".to_string()]);
        assert!(v.hold.is_none());
    }

    #[test]
    fn a_replying_second_mutation_with_a_malformed_target_holds_compute() {
        let mut holds = Holds::new();
        let long = "x".repeat(MAX_ID + 1);
        let v = holds.apply(&revoke_in(DM, &long, DM), None);
        assert_eq!(v.proof, "target_id_invalid");
        assert!(v.fence_everywhere.is_empty());
        assert!(holds.compute_held(DM));
    }

    #[test]
    fn a_hold_is_reproved_when_the_store_proves_every_evidence_target() {
        let mut holds = Holds::new();
        holds.apply(&revoke_in(LID, "MSG1", DM), None);
        assert!(holds.posting_held(LID));
        // Later the message shows up in the chat, by the same author: the hold is provable.
        let report = holds.reprove(LID, |id| (id == "MSG1").then(|| Author::new(DM, "", false)));
        assert_eq!((report.reproved, report.fenced), (1, 1));
        assert!(!holds.posting_held(LID), "posting resumes");
        assert!(holds.blocked(LID, "MSG1"), "the exact message stays fenced");
    }

    #[test]
    fn a_hold_stays_when_the_evidence_is_not_all_provable() {
        let mut holds = Holds::new();
        holds.apply(&revoke_in(LID, "MSG1", DM), None);
        holds.apply(&revoke_in(LID, "MSG2", "5511888@s.whatsapp.net"), None);
        let report = holds.reprove(LID, |id| (id == "MSG1").then(|| Author::new(DM, "", false)));
        assert_eq!(report.skipped, Some("target_not_in_chat"));
        assert!(holds.posting_held(LID), "one unproven mutation keeps the hold");

        let mut holds = Holds::new();
        holds.apply(&revoke_in(LID, "MSG1", DM), None);
        let report = holds.reprove(LID, |_| Some(Author::new("5511888@s.whatsapp.net", "", false)));
        assert_eq!(report.skipped, Some("author_unproven"));
        assert!(holds.posting_held(LID));
    }

    #[test]
    fn a_compute_hold_is_never_reproved() {
        let mut holds = Holds::new();
        let mut untargeted = Mutation::revoke(LID, "");
        untargeted.kind = "edit".into();
        holds.apply(&untargeted, None);
        let report = holds.reprove(LID, |_| Some(Author::new(DM, "", false)));
        assert_eq!(report.skipped, Some("other_hold"));
        assert!(holds.compute_held(LID));
    }

    #[test]
    fn holds_survive_a_round_trip_through_json() {
        let mut holds = Holds::new();
        holds.apply(&revoke_in(LID, "MSG1", DM), None);
        holds.apply(&revoke_in(DM, "MSG2", DM), Some(&author(DM)));
        let back = Holds::from_json(&holds.to_json());
        assert_eq!(back, holds);
        assert!(back.posting_held(LID) && back.blocked(DM, "MSG2") && back.blocked(LID, "MSG1"));
        assert_eq!(Holds::from_json("not json"), Holds::new());
    }

    #[test]
    fn a_bare_user_jid_is_required_for_author_proof() {
        assert!(valid_user("5511999@s.whatsapp.net") && valid_user("7210397@lid"));
        assert!(!valid_user("5511999:12@s.whatsapp.net"), "a device part is not a user");
        assert!(!valid_user("1203@g.us") && !valid_user("") && !valid_user("abc@s.whatsapp.net"));
        assert!(author_equivalent("1@lid", "2@s.whatsapp.net", "2@s.whatsapp.net", ""));
        assert!(!author_equivalent("1@lid", "", "2@s.whatsapp.net", ""));
    }
}
