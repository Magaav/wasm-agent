//! The explicit-send outbox: one ordinary WhatsApp message somebody asked for.
//!
//! The owner's decision (06/11) is that the new bridge sends ordinary messages freely, to any chat -
//! like the old connector did - and *on the architecture*: a request is a job on the shared durable
//! queue (`wa:queue`, queue name [`QUEUE`]), not a hidden side path. The node enqueues it (after the
//! `whatsapp.send` policy check, `docs/GRANT-POLICY.md`), the `wa-whatsapp` component consumes it and
//! reports `done(message id)` or `fail(reason)`, and an operator reads the state back with the same
//! id.
//!
//! This crate is the part both ends must agree on, and it is deliberately small and pure:
//!
//! * [`Chat`] - the exact JID a request may name (phone number, LID, group) and why anything else is
//!   refused. The specification is "exact JID", so a bare number, a `@broadcast`/`@newsletter`
//!   address, a device-specific `user:12@…` or a server this library cannot send to is a refusal
//!   with a stable code, never a guess. A group may also carry the legacy `<digits>-<digits>@g.us`
//!   id (creator phone, hyphen, creation epoch): it is what an older group is really called, so it
//!   is a chat a caller can name, not a malformed number.
//! * [`Request`] - `{chat, text, reply_to?, mentions?}` as it travels in the job payload, plus the
//!   dedupe key the job brief fixes: `sha256(chat|text|reply_to)`.
//! * [`decide`] - what the worker does with a taken job: send these bytes, or refuse (this also
//!   catches a job that turned stale between `take` and dispatch, so a request the queue never
//!   expired by itself is still never sent late).
//! * [`Outcome`] - what `done` carries: the message id, so `whatsapp_send_status` can answer "sent,
//!   here is its id" without reading the chat.
//!
//! Nothing here logs, and nothing here stores text: the payload is the only place message text lives,
//! and it lives in the queue's kv until the job is settled and reaped (`docs/QUEUE.md`).
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

/// The queue every explicit send travels on (`docs/SERVICE-COMPONENTS.md`).
pub const QUEUE: &str = "whatsapp.outbox";
/// A request nobody picked up within this window is never sent (`fresh_for_ms`, job brief: 5 min).
pub const FRESH_MS: i64 = 300_000;
/// Attempts before a retryable send failure becomes final (job brief: 3).
pub const MAX_ATTEMPTS: u32 = 3;
/// Longest text one request may carry, in characters.
pub const MAX_TEXT: usize = 65_536;
/// Most mentions one request may name.
pub const MAX_MENTIONS: usize = 64;
/// Longest accepted JID user part.
const MAX_USER: usize = 32;
/// Longest accepted message id in `reply_to`.
const MAX_REPLY_TO: usize = 128;

/// Which server a chat lives on. Exactly the three this library can send to, so the enum is the
/// whole accept list: `s.whatsapp.net` (phone number), `lid` (the hidden LID identity) and `g.us`
/// (group). Anything else - `broadcast` (status), `newsletter` (channels), `bot`, … - is refused
/// before a byte leaves the node.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Server {
    Phone,
    Lid,
    Group,
}

impl Server {
    pub fn as_str(self) -> &'static str {
        match self {
            Server::Phone => "s.whatsapp.net",
            Server::Lid => "lid",
            Server::Group => "g.us",
        }
    }

    fn parse(text: &str) -> Option<Server> {
        match text {
            // The legacy spelling of the phone-number server; normalized, never sent as `c.us`.
            "s.whatsapp.net" | "c.us" => Some(Server::Phone),
            "lid" => Some(Server::Lid),
            "g.us" => Some(Server::Group),
            _ => None,
        }
    }
}

/// One exact chat JID, split and validated.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Chat {
    pub user: String,
    pub server: Server,
}

impl Chat {
    /// Parse an exact JID: `<digits>@s.whatsapp.net`, `<digits>@lid`, `<digits>@g.us`, or - for a
    /// group only - the legacy `<digits>-<digits>@g.us` id (creator phone, hyphen, creation epoch).
    ///
    /// Refusals are per-shape and carry a stable code ([`Refusal::code`]) so the tool answer, the log
    /// line and the test can name the same thing: `bad_chat` for a bare number / empty / control
    /// characters / a device suffix (`user:12@…`) / any user part that is not a digit run (a letter,
    /// two hyphens, an empty half, a hyphen on a person JID), `unsupported_chat` for a server this
    /// component cannot send to.
    pub fn parse(text: &str) -> Result<Chat, Refusal> {
        let text = text.trim();
        if text.is_empty() {
            return Err(Refusal::new("bad_chat", "empty chat: pass an exact JID"));
        }
        if text.chars().count() > MAX_USER + 1 + 20 {
            return Err(Refusal::new("bad_chat", "chat JID is too long"));
        }
        if text.chars().any(|c| c.is_control() || c.is_whitespace()) {
            return Err(Refusal::new("bad_chat", "chat JID contains whitespace or a control character"));
        }
        let Some((user, server)) = text.rsplit_once('@') else {
            return Err(Refusal::new(
                "bad_chat",
                "chat is not an exact JID (expected <digits>@s.whatsapp.net, <digits>@lid or <digits>@g.us)",
            ));
        };
        if user.is_empty() || user.chars().count() > MAX_USER {
            return Err(Refusal::new("bad_chat", "chat JID user part is empty or too long"));
        }
        if user.contains(':') {
            return Err(Refusal::new(
                "bad_chat",
                "chat JID names a device (user:device@…); a chat is device-less",
            ));
        }
        // The user part's shape depends on the server: the hyphen belongs to a group id and nowhere
        // else. Reading the server first is what lets `999…-999…@g.us` be a chat and
        // `999…-999…@s.whatsapp.net` stay a refusal - a phone number has no hyphen in it.
        let known = Server::parse(server);
        if !user_shape_ok(user, known) {
            return Err(Refusal::new(
                "bad_chat",
                "chat JID user part is not numeric (a legacy group id is <digits>-<digits> in a group only)",
            ));
        }
        let Some(server) = known else {
            return Err(Refusal::new(
                "unsupported_chat",
                "chat server is not sendable (accepted: s.whatsapp.net, lid, g.us)",
            ));
        };
        Ok(Chat { user: user.to_string(), server })
    }

    /// The canonical JID string (`c.us` is normalized to `s.whatsapp.net`).
    pub fn jid(&self) -> String {
        format!("{}@{}", self.user, self.server.as_str())
    }

    pub fn is_group(&self) -> bool {
        self.server == Server::Group
    }
}

/// Is one non-empty run of ASCII digits?
fn digit_run(text: &str) -> bool {
    !text.is_empty() && text.chars().all(|c| c.is_ascii_digit())
}

/// Is this user part a chat on the server it names?
///
/// A person (phone number or LID) is one digit run. A group is a digit run too - the modern
/// `120363…` id - or the legacy `<creator phone>-<creation epoch>` form: **exactly one** hyphen
/// between **two** digit runs, both non-empty. Nothing else is a user part: `1-2-3`, `-1`, `1-`,
/// `1--2`, `12a-3` and a hyphen on a person JID are all refused, and an unknown server never buys
/// the legacy form.
fn user_shape_ok(user: &str, server: Option<Server>) -> bool {
    if digit_run(user) {
        return true;
    }
    if server != Some(Server::Group) {
        return false;
    }
    match user.split_once('-') {
        Some((creator, epoch)) => digit_run(creator) && digit_run(epoch),
        None => false,
    }
}

/// Why a request was refused. `code` is a stable snake_case word; `detail` is one short line that
/// never contains message text (the caller's text is not repeated back, in a log or an answer).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refusal {
    pub code: &'static str,
    pub detail: String,
}

impl Refusal {
    pub fn new(code: &'static str, detail: impl Into<String>) -> Refusal {
        let detail: String = detail.into().chars().take(160).collect();
        Refusal { code, detail }
    }

    /// The tool answer's error word: `whatsapp_send_<code>`.
    pub fn error(&self) -> String {
        format!("whatsapp_send_{}", self.code)
    }
}

/// One send request as it travels in the job payload.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Request {
    /// Exact JID (see [`Chat::parse`]).
    #[serde(default)]
    pub chat: String,
    /// The message body, exactly as the caller wrote it.
    #[serde(default)]
    pub text: String,
    /// Optional message id whose message this quotes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reply_to: Option<String>,
    /// Optional mention targets (users, exact JIDs; only meaningful in a group).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub mentions: Vec<String>,
}

/// A request that passed every check, with the JIDs already parsed. This is what the component
/// hands to the client, so "validated" and "sent" cannot drift apart.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Verified {
    pub chat: Chat,
    pub text: String,
    pub reply_to: Option<String>,
    pub mentions: Vec<Chat>,
}

impl Request {
    /// Check every field. The first refusal wins; a request is all-or-nothing.
    pub fn validate(&self) -> Result<Verified, Refusal> {
        let chat = Chat::parse(&self.chat)?;
        if self.text.is_empty() {
            return Err(Refusal::new("empty_text", "text is empty"));
        }
        if self.text.chars().count() > MAX_TEXT {
            return Err(Refusal::new("text_too_long", "text is longer than 65536 characters"));
        }
        let reply_to = match self.reply_to.as_deref().map(str::trim) {
            None | Some("") => None,
            Some(id) => {
                if id.chars().count() > MAX_REPLY_TO {
                    return Err(Refusal::new("bad_reply_to", "reply_to is longer than 128 characters"));
                }
                if !id.chars().all(|c| c.is_ascii_alphanumeric()) {
                    return Err(Refusal::new("bad_reply_to", "reply_to is not a message id"));
                }
                Some(id.to_string())
            }
        };
        if self.mentions.len() > MAX_MENTIONS {
            return Err(Refusal::new("too_many_mentions", "more than 64 mentions"));
        }
        let mut mentions = Vec::with_capacity(self.mentions.len());
        for raw in &self.mentions {
            let user = Chat::parse(raw)?;
            if user.is_group() {
                return Err(Refusal::new("bad_mention", "a group cannot be mentioned"));
            }
            if !mentions.contains(&user) {
                mentions.push(user);
            }
        }
        Ok(Verified { chat, text: self.text.clone(), reply_to, mentions })
    }

    /// The producer's idempotency key, exactly as the job brief fixes it:
    /// `sha256(chat|text|reply_to)`, hex. `reply_to` contributes an empty field when absent, so the
    /// same text sent twice as a plain message is one job, and the same text sent as a reply to two
    /// different messages is two.
    pub fn dedupe_key(&self) -> String {
        let material = format!(
            "{}|{}|{}",
            self.chat.trim(),
            self.text,
            self.reply_to.as_deref().unwrap_or("")
        );
        hex(&Sha256::digest(material.as_bytes()))
    }

    /// The payload bytes for the queue. JSON, because a payload that cannot be read back must be
    /// droppable (and the queue keeps bytes opaque either way).
    pub fn encode(&self) -> Vec<u8> {
        serde_json::to_vec(self).unwrap_or_default()
    }

    /// Read a payload back. A payload this crate did not write is `malformed`, never guessed at.
    pub fn decode(bytes: &[u8]) -> Result<Request, Refusal> {
        serde_json::from_slice(bytes)
            .map_err(|_| Refusal::new("malformed_job", "the job payload is not a whatsapp send request"))
    }
}

/// What the worker must do with a taken job.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Decision {
    /// Send exactly this, then settle `done` with the message id.
    Send(Box<Verified>),
    /// Do not send, and do not retry: a permanent answer (`code` is stable, `detail` is one line).
    Refuse(Refusal),
}

/// Decide one job: is this a send, and is it still fresh?
///
/// `fresh_until` comes from the job record, so a job that went stale between `take` and dispatch - a
/// clock jump, a component that woke up late - is refused here even though the queue would not have
/// handed it out. "A stale request is never sent" does not depend on one check being enough.
pub fn decide(payload: &[u8], now_ms: i64, fresh_until: Option<i64>) -> Decision {
    if fresh_until.is_some_and(|fresh| fresh <= now_ms) {
        return Decision::Refuse(Refusal::new("stale", "the request went stale before dispatch"));
    }
    match Request::decode(payload).and_then(|request| request.validate()) {
        Ok(verified) => Decision::Send(Box::new(verified)),
        Err(refusal) => Decision::Refuse(refusal),
    }
}

/// Is a failure reason worth another attempt? A refusal (shape, policy, staleness, logged-out) is
/// permanent; a transport failure is not. The queue decides *how many* attempts a retryable failure
/// gets; this only says whether retrying can possibly help.
pub fn retryable(reason: &str) -> bool {
    const PERMANENT: [&str; 12] = [
        "bad_chat",
        "bad_mention",
        "bad_reply_to",
        "empty_text",
        "text_too_long",
        "too_many_mentions",
        "malformed_job",
        "stale",
        "unsupported_chat",
        "not_logged_in",
        "logged_out",
        "policy_denied",
    ];
    !PERMANENT.iter().any(|code| reason == *code || reason.starts_with(&format!("{code}:")))
}

/// What `done` carries: the id WhatsApp gave the message.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Outcome {
    pub message_id: String,
}

impl Outcome {
    pub fn encode(&self) -> Vec<u8> {
        serde_json::to_vec(self).unwrap_or_default()
    }

    pub fn decode(bytes: &[u8]) -> Option<Outcome> {
        serde_json::from_slice(bytes).ok()
    }
}

/// How the tool names a job the queue stores as `ready`: "queued" is what a caller asked for and
/// understands, and the queue's `ready` (including a retry waiting out its backoff) is that state. Every
/// other word is the queue's own, so an operator can read both sides without a translation table.
pub fn state_word(queue_state: &str) -> &str {
    match queue_state {
        "ready" => "queued",
        other => other,
    }
}

/// The `whatsapp_send_status` shape, built here so the host answer and the documented answer cannot
/// differ. Counts and an id only: never the text, never the chat.
pub fn status(
    id: u64,
    state: &str,
    attempts: u32,
    result: Option<&[u8]>,
    last_error: Option<&str>,
) -> serde_json::Value {
    let message_id = result.and_then(Outcome::decode).map(|outcome| outcome.message_id);
    let state = state_word(state);
    let mut answer = serde_json::json!({
        "ok": true,
        "id": id,
        "state": state,
        "attempts": attempts,
    });
    if let Some(message_id) = message_id {
        answer["message_id"] = serde_json::Value::String(message_id);
    }
    if !state.eq("done") {
        if let Some(reason) = last_error {
            answer["reason"] = serde_json::Value::String(reason.chars().take(160).collect());
        }
    }
    answer
}

fn hex(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn req(chat: &str, text: &str) -> Request {
        Request { chat: chat.into(), text: text.into(), reply_to: None, mentions: Vec::new() }
    }

    #[test]
    fn the_three_sendable_servers_are_accepted_and_canonicalized() {
        let pn = Chat::parse("5511999999999@s.whatsapp.net").unwrap();
        assert_eq!((pn.server, pn.jid().as_str()), (Server::Phone, "5511999999999@s.whatsapp.net"));
        let lid = Chat::parse("72103978127547@lid").unwrap();
        assert_eq!((lid.server, lid.jid().as_str()), (Server::Lid, "72103978127547@lid"));
        let group = Chat::parse("120363000000000001@g.us").unwrap();
        assert!(group.is_group() && group.jid().ends_with("@g.us"));
        // The legacy phone-number server is the phone server, not a fourth kind of chat.
        assert_eq!(Chat::parse("5511999999999@c.us").unwrap().jid(), "5511999999999@s.whatsapp.net");
        // Surrounding whitespace is never part of a JID.
        assert_eq!(Chat::parse(" 5511999999999@lid ").unwrap().user, "5511999999999");
    }

    #[test]
    fn a_legacy_group_id_is_a_chat_and_the_hyphen_belongs_to_a_group_only() {
        // The live shape (07/11): a group that predates the `120363…` ids is named by its creator's
        // phone number, a hyphen and the creation epoch. It is the chat's real name, so it is a chat.
        let legacy = "9999999999999-9999999999@g.us";
        let chat = Chat::parse(legacy).expect(legacy);
        assert_eq!((chat.user.as_str(), chat.server), ("9999999999999-9999999999", Server::Group));
        assert!(chat.is_group());
        // Round trip: what `jid()` hands the client is what the caller (and the index hit) said.
        assert_eq!(chat.jid(), legacy);
        // A one-digit creator or epoch is still a digit run: the rule is shape, not length.
        assert_eq!(Chat::parse("1-2@g.us").unwrap().jid(), "1-2@g.us");
        // And a send to it validates, which is the whole point of the finding.
        assert_eq!(req(legacy, "oi").validate().unwrap().chat.jid(), legacy);
        // A legacy group is still a group for the mention rule: it cannot be mentioned.
        let mut mentions = req("120363000000000001@g.us", "oi");
        mentions.mentions = vec![legacy.into()];
        assert_eq!(mentions.validate().unwrap_err().code, "bad_mention");
    }

    #[test]
    fn the_legacy_hyphen_is_refused_everywhere_it_is_not_a_group_id() {
        for text in [
            // A person has no hyphen: the legacy form is a group id, not a number with punctuation.
            "9999999999999-9999999999@s.whatsapp.net",
            "9999999999999-9999999999@lid",
            "9999999999999-9999999999@c.us",
            // Exactly one hyphen between exactly two non-empty digit runs - nothing else.
            "9999999999999-9999999999-9999999999@g.us",
            "9999999999999--9999999999@g.us",
            "-9999999999@g.us",
            "9999999999999-@g.us",
            "9999999999999-999a999999@g.us",
            "a999999999999-9999999999@g.us",
            "9999999999999 - 9999999999@g.us",
            "9999999999999:12-9999999999@g.us",
            // An unsendable server never buys the legacy user shape.
            "9999999999999-9999999999@broadcast",
        ] {
            let refusal = Chat::parse(text).expect_err(text);
            assert_eq!(refusal.code, "bad_chat", "{text:?}");
            assert_eq!(refusal.error(), "whatsapp_send_bad_chat", "{text:?}");
            assert_eq!(req(text, "oi").validate().unwrap_err().code, "bad_chat", "{text:?}");
        }
        // A legacy group whose user part is too long for the field is still refused as too long.
        let too_long = format!("{}-{}@g.us", "9".repeat(32), "9".repeat(10));
        assert_eq!(Chat::parse(&too_long).unwrap_err().code, "bad_chat");
    }

    #[test]
    fn a_chat_that_is_not_an_exact_sendable_jid_is_refused_with_a_code() {
        for (text, code) in [
            ("", "bad_chat"),
            ("5511999999999", "bad_chat"),
            ("@lid", "bad_chat"),
            ("55a1@lid", "bad_chat"),
            ("5511:12@s.whatsapp.net", "bad_chat"),
            ("5511 999@lid", "bad_chat"),
            ("5511999999999@broadcast", "unsupported_chat"),
            ("120363000000000001@newsletter", "unsupported_chat"),
            ("5511\t999@lid", "bad_chat"),
        ] {
            let refusal = Chat::parse(text).expect_err(text);
            assert_eq!(refusal.code, code, "{text:?}");
            assert_eq!(refusal.error(), format!("whatsapp_send_{code}"));
        }
    }

    #[test]
    fn text_reply_to_and_mentions_are_checked() {
        assert_eq!(req("5511999999999@lid", "").validate().unwrap_err().code, "empty_text");
        assert_eq!(
            req("5511999999999@lid", &"a".repeat(MAX_TEXT + 1)).validate().unwrap_err().code,
            "text_too_long"
        );
        assert_eq!(req("5511999999999@lid", &"a".repeat(MAX_TEXT)).validate().unwrap().text.len(), MAX_TEXT);
        let mut bad_reply = req("5511999999999@lid", "ok");
        bad_reply.reply_to = Some("3EB0 NOT-AN-ID".into());
        assert_eq!(bad_reply.validate().unwrap_err().code, "bad_reply_to");
        // An empty reply_to is "no quote", not a refusal: a tool call that passes "" means nothing.
        let mut empty_reply = req("5511999999999@lid", "ok");
        empty_reply.reply_to = Some(String::new());
        assert!(empty_reply.validate().unwrap().reply_to.is_none());
        let mut mentions = req("120363000000000001@g.us", "hello");
        mentions.mentions = vec!["5511888888888@s.whatsapp.net".into(), "5511888888888@s.whatsapp.net".into(), "72103978127547@lid".into()];
        let verified = mentions.validate().unwrap();
        assert_eq!(verified.mentions.len(), 2, "mentions are deduplicated");
        mentions.mentions = vec!["120363000000000001@g.us".into()];
        assert_eq!(mentions.validate().unwrap_err().code, "bad_mention");
        mentions.mentions = vec!["5511888888888".into()];
        assert_eq!(mentions.validate().unwrap_err().code, "bad_chat");
        mentions.mentions = (0..MAX_MENTIONS + 1).map(|i| format!("55118888888{i:02}@lid")).collect();
        assert_eq!(mentions.validate().unwrap_err().code, "too_many_mentions");
    }

    #[test]
    fn the_dedupe_key_is_sha256_of_chat_pipe_text_pipe_reply_to() {
        // The exact bytes the brief fixes, checked against a hand-computed digest so a future
        // "improvement" to the key is a test failure rather than a silent double send.
        let mut request = req("5511999999999@lid", "oi");
        request.reply_to = Some("3EB0ABCD".into());
        assert_eq!(
            request.dedupe_key(),
            hex(&Sha256::digest(b"5511999999999@lid|oi|3EB0ABCD"))
        );
        assert_eq!(
            req("5511999999999@lid", "oi").dedupe_key(),
            hex(&Sha256::digest(b"5511999999999@lid|oi|"))
        );
        // Same text, different chat or different quote: three different jobs.
        let a = req("1@lid", "x").dedupe_key();
        let b = req("2@lid", "x").dedupe_key();
        let mut c = req("1@lid", "x");
        c.reply_to = Some("M".into());
        assert_ne!(a, b);
        assert_ne!(a, c.dedupe_key());
        assert_eq!(a.len(), 64);
    }

    #[test]
    fn a_payload_round_trips_and_a_foreign_payload_is_not_guessed() {
        let request = Request {
            chat: "120363000000000001@g.us".into(),
            text: "olá, mundo".into(),
            reply_to: Some("3EB0ABCD".into()),
            mentions: vec!["5511999999999@s.whatsapp.net".into()],
        };
        let bytes = request.encode();
        assert_eq!(Request::decode(&bytes).unwrap(), request);
        assert_eq!(Request::decode(b"not json").unwrap_err().code, "malformed_job");
        assert_eq!(Request::decode(b"{}").unwrap().validate().unwrap_err().code, "bad_chat");
    }

    #[test]
    fn decide_refuses_a_stale_job_and_a_bad_one_before_anything_is_sent() {
        let request = req("5511999999999@lid", "oi");
        let payload = request.encode();
        assert!(matches!(decide(&payload, 1_000, Some(2_000)), Decision::Send(_)));
        // The queue would have expired it; this is the second, independent rule.
        match decide(&payload, 2_000, Some(2_000)) {
            Decision::Refuse(refusal) => assert_eq!(refusal.code, "stale"),
            Decision::Send(_) => panic!("a stale job must not be sent"),
        }
        match decide(b"{}", 0, None) {
            Decision::Refuse(refusal) => assert_eq!(refusal.code, "bad_chat"),
            Decision::Send(_) => panic!("an invalid job must not be sent"),
        }
        // No freshness bound means no staleness rule, not "always stale".
        assert!(matches!(decide(&payload, i64::MAX / 2, None), Decision::Send(_)));
    }

    #[test]
    fn only_a_transport_failure_is_worth_retrying() {
        assert!(retryable("timeout"));
        assert!(retryable("connection closed"));
        for code in ["bad_chat", "stale", "unsupported_chat", "not_logged_in", "policy_denied"] {
            assert!(!retryable(code), "{code}");
        }
        assert!(!retryable("bad_reply_to:detail"), "a code with a detail suffix is still permanent");
        assert!(retryable("bad_reply_tos"), "a prefix that is not the code itself is not the code");
    }

    #[test]
    fn a_ready_job_is_called_queued_and_the_queues_own_words_are_kept() {
        assert_eq!(state_word("ready"), "queued");
        for word in ["leased", "done", "dead", "expired"] {
            assert_eq!(state_word(word), word);
        }
    }

    #[test]
    fn status_reports_the_message_id_only_once_the_job_is_done() {
        let done = status(7, "done", 1, Some(&Outcome { message_id: "3EB0".into() }.encode()), None);
        assert_eq!(done["message_id"], "3EB0");
        assert_eq!(done["state"], "done");
        let failed = status(8, "ready", 2, None, Some("timeout"));
        assert_eq!(failed["reason"], "timeout");
        assert!(failed.get("message_id").is_none());
        // A done job never reports a stale error reason beside its id.
        let settled = status(9, "done", 2, Some(&Outcome { message_id: "X".into() }.encode()), Some("earlier"));
        assert!(settled.get("reason").is_none());
    }
}
