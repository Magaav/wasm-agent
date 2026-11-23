//! The outbox's decisions that need no host: what a verified request becomes on the wire, and which
//! failures are worth another attempt.
//!
//! The queue contract, the payload and the refusals live in `wa-whatsapp-outbox` (shared with the
//! node, `rust/wa-capabilities/src/whatsapp_send.rs`). What is left is the shape of the WhatsApp message this
//! component sends, which is worth its own module because it is the one place a change could silently
//! drop a quote or a mention: it compiles natively, so `cargo test` pins it without a wasm target and
//! without a connection.
use wacore::proto_helpers::MessageBuilderExt;
use whatsapp_rust::waproto::whatsapp as wap;

/// The wire message for one request: plain text when there is nothing attached, an extended text
/// carrying the quote and the mentions otherwise (WA Web switches from `conversation` to
/// `extendedTextMessage` as soon as a context is attached).
///
/// * `reply_to` becomes `contextInfo.stanzaId`. The quoted *body* is not fetched - this component keeps
///   no message history - so the client renders a reference-only quote. In a group WhatsApp names the
///   quoted author and we do not know it, so `participant` names the chat rather than a wrong person.
/// * `mentions` become `contextInfo.mentionedJid`, as full user JIDs (phone number or LID), which is
///   how a group notification is addressed. They are carried for any chat: a mention in a direct chat
///   is ignored by WhatsApp, and refusing it would make one caller special.
pub fn build_message(request: &wa_whatsapp_outbox::Verified) -> wap::Message {
    let mut context = wap::ContextInfo::default();
    if let Some(reply_to) = &request.reply_to {
        context.stanza_id = Some(reply_to.clone());
        if request.chat.is_group() {
            context.participant = Some(request.chat.jid());
        }
    }
    if !request.mentions.is_empty() {
        context.mentioned_jid = request.mentions.iter().map(|mention| mention.jid()).collect();
    }
    if request.reply_to.is_some() || !request.mentions.is_empty() {
        wap::Message::text_with_context(request.text.clone(), context)
    } else {
        wap::Message::text(request.text.clone())
    }
}

/// Is a send failure worth the queue's next attempt? The crate's rule, kept beside the send so a
/// caller cannot forget it: a refusal (bad address, logged out, policy) is permanent, a transport
/// failure is not.
pub fn retryable(reason: &str) -> bool {
    wa_whatsapp_outbox::retryable(reason)
}

/// What this instance's own bot is doing, and the rule the outbox asks before it claims
/// ([`wa_whatsapp_outbox::may_claim`]): the seam owns it because both ends of the queue must agree and
/// its tests run on every node's gate. `Bot::Stopped` is the state 11/11 needed - the protocol task
/// returned (`bot stopped`) while the pipeline was still ticking, and the outbox went on claiming jobs
/// and failing them `client is not connected` while the replacement instance was `CONNECTED` (jobs 73
/// and 74).
pub use wa_whatsapp_outbox::{claim_refusal, may_claim, Bot};

/// The facts about a reply source this component can prove from its own index. It is the subset of
/// `record::Record` the dispatch gate needs, so the rule compiles and is tested without a store.
pub struct SourceFacts {
    pub kind: String,
    pub text: String,
    pub own: bool,
    pub deleted: bool,
    pub unsupported: String,
    pub ts: i64,
}

/// A refusal with the fact that names it: the stable code a caller switches on, and the message id the
/// refusal is about (`""` when the refusal names no message).
///
/// The id is there because a code alone does not answer *which* message: on 23/11 a send was refused
/// with one word and no chat, no id and no date, and four rounds of a session went into finding out what
/// the word was about. The caller named this id itself, so echoing it back tells it nothing it did not
/// say. It is never logged: the log line keeps the code, and `privacy` marks the id.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refusal {
    pub code: &'static str,
    pub about: String,
}

impl Refusal {
    fn about(code: &'static str, id: &str) -> Refusal {
        Refusal { code, about: id.chars().take(128).collect() }
    }

    /// What the queue stores as the job's failure reason: `code` alone when no message is named,
    /// `code:<id>` otherwise. `wa_whatsapp_outbox::retryable` keeps reading the head.
    pub fn stored(&self) -> String {
        if self.about.is_empty() {
            self.code.to_string()
        } else {
            format!("{}:{}", self.code, self.about)
        }
    }
}

/// What a verified request carries as its quote.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Quote {
    /// Send it as asked: a plain message, a reference quote, or a quote of a message that still exists.
    Keep,
    /// Send the message WITHOUT the quote, and say this to the caller: the quoted message was deleted by
    /// its author, and a quote re-publishes its text (WhatsApp puts the quoted message in the context).
    Drop(&'static str),
}

/// The rule for the quote, decided from the index before the wire (Fable's review, 23/11 ~20:30Z).
///
/// The node KEEPS a deleted message for the operator to read - that is the owner's decision of 23/11 - and
/// keeping it is not permission to send it back into the chat its author took it out of. So an explicit
/// send that names a deleted message as its reply source still GOES OUT, and the quote is dropped with the
/// sentence [`wa_whatsapp_outbox::QUOTE_DROPPED_DELETED`] on the result. A send whose source the index does
/// not hold at all is a refusal one layer up (`dispatch_refusal`), not this.
pub fn quote_decision(source: Option<&SourceFacts>) -> Quote {
    match source {
        Some(facts) if facts.deleted => Quote::Drop(wa_whatsapp_outbox::QUOTE_DROPPED_DELETED),
        _ => Quote::Keep,
    }
}

/// The last gate before the wire: why this verified request must not be dispatched, if it must not.
///
/// The placement is deliberate and is the Go connector's: the node already asked its policy, but the
/// index can have learned something about the quoted message while the job waited, and only the
/// component holds that state. A refusal is never a retry.
///
/// WHAT IS NOT HERE ANY MORE (23/11). There is no chat gate: no revoke, no edit and no clear on the wire
/// refuses an explicit send, and this function no longer has a parameter for one. A message the owner
/// deletes is flagged and kept (`index::mark_deleted`), and quoting it is allowed - the owner's rule is
/// that this node never refuses his send *for a deletion*.
///
/// A reply source is still checked exactly, from the index, because the refusal is about what the quote
/// would RENDER, not about a deletion: a quote of an own message, of an unsupported bubble or of a
/// non-text message would show as something the operator did not approve.
pub fn dispatch_refusal(reply_to: Option<&str>, source: Option<&SourceFacts>) -> Option<Refusal> {
    let reply = reply_to?;
    let Some(source) = source else { return Some(Refusal::about("reply_source_not_indexed", reply)) };
    if source.own {
        return Some(Refusal::about("reply_source_own", reply));
    }
    if !source.unsupported.is_empty() {
        return Some(Refusal::about("reply_source_unsupported", reply));
    }
    if source.kind != "text" || source.text.trim().is_empty() || source.ts <= 0 {
        return Some(Refusal::about("reply_source_not_plain_text", reply));
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use wa_whatsapp_outbox::{Chat, Request, Verified};

    /// The rule the 09-11 failure needed is tested where the gate runs it (the seam crate); this only
    /// keeps the re-export honest for the guest that uses it.
    #[test]
    fn the_seam_rule_is_the_one_this_module_exposes() {
        assert!(may_claim(Bot::Connected));
        assert!(!may_claim(Bot::Stopped));
    }

    fn verified(request: Request) -> Verified {
        request.validate().expect("a valid request")
    }

    #[test]
    fn a_plain_message_stays_a_conversation() {
        let request = verified(Request { chat: "5511999999999@lid".into(), text: "oi".into(), reply_to: None, mentions: Vec::new() });
        let message = build_message(&request);
        assert_eq!(message.conversation.as_deref(), Some("oi"));
        assert!(message.extended_text_message.is_unset(), "no context, no extended text");
    }

    #[test]
    fn a_quote_is_a_reference_and_a_group_quote_names_the_chat() {
        let dm = verified(Request {
            chat: "5511999999999@s.whatsapp.net".into(),
            text: "olha isto".into(),
            reply_to: Some("3EB0ABCD".into()),
            mentions: Vec::new(),
        });
        let message = build_message(&dm);
        let extended = message.extended_text_message.as_option().expect("extended text");
        assert_eq!(extended.text.as_deref(), Some("olha isto"));
        let context = extended.context_info.as_option().expect("context");
        assert_eq!(context.stanza_id.as_deref(), Some("3EB0ABCD"));
        assert!(context.participant.is_none(), "a direct chat needs no quoted author");
        assert!(context.quoted_message.is_unset(), "the quoted body is not fetched, never invented");

        let group = verified(Request {
            chat: "120363000000000001@g.us".into(),
            text: "olha isto".into(),
            reply_to: Some("3EB0ABCD".into()),
            mentions: Vec::new(),
        });
        let message = build_message(&group);
        let context = message
            .extended_text_message
            .as_option()
            .and_then(|extended| extended.context_info.as_option())
            .expect("context");
        assert_eq!(context.participant.as_deref(), Some("120363000000000001@g.us"));
    }

    #[test]
    fn mentions_travel_as_full_user_jids() {
        let group = verified(Request {
            chat: "120363000000000001@g.us".into(),
            text: "@5511 olha".into(),
            reply_to: None,
            mentions: vec!["5511888888888@s.whatsapp.net".into(), "72103978127547@lid".into()],
        });
        let message = build_message(&group);
        let context = message
            .extended_text_message
            .as_option()
            .and_then(|extended| extended.context_info.as_option())
            .expect("mentions attach a context");
        assert_eq!(context.mentioned_jid, vec!["5511888888888@s.whatsapp.net", "72103978127547@lid"]);
        assert!(context.stanza_id.is_none(), "a mention is not a reply");
    }

    #[test]
    fn the_chat_the_request_names_is_the_chat_the_client_is_given() {
        // No mapping, in either direction: a LID is sent to as a LID (the library addresses it), and a
        // phone number is never substituted for it.
        //
        // The last one is the legacy group id a `whatsapp_search` hit can return (07/11): the send path
        // hands the client `request.chat.jid()` and the library parses it (`guest::send_outbox`), so a
        // value the seam accepts but the library refuses would be a `bad_chat` one layer deeper.
        for jid in [
            "72103978127547@lid",
            "5511999999999@s.whatsapp.net",
            "120363000000000001@g.us",
            "9999999999999-9999999999@g.us",
        ] {
            let chat = Chat::parse(jid).expect(jid);
            assert_eq!(chat.jid(), jid);
            let parsed: whatsapp_rust::Jid = chat.jid().parse().expect("the library parses it");
            assert_eq!(parsed.to_string(), jid);
        }
        // And the hyphen is still a group's: the same user part on a person's server is refused by the
        // seam, so the library never sees it.
        assert_eq!(Chat::parse("9999999999999-9999999999@s.whatsapp.net").unwrap_err().code, "bad_chat");
    }

    #[test]
    fn a_refusal_is_never_retried_and_a_transport_failure_is() {
        assert!(!retryable("bad_chat"));
        assert!(!retryable("not_logged_in"));
        assert!(retryable("websocket closed"));
        assert!(retryable("timeout"));
    }

    fn source(kind: &str, text: &str, own: bool) -> SourceFacts {
        SourceFacts { kind: kind.into(), text: text.into(), own, deleted: false, unsupported: String::new(), ts: 1_760_000_000_000 }
    }

    #[test]
    fn a_clean_quote_goes_out_and_no_deletion_refuses_a_send() {
        let plain = source("text", "oi", false);
        assert_eq!(dispatch_refusal(None, None), None, "no reply, no gate: a chat can never block a send");
        assert_eq!(dispatch_refusal(Some("3EB0"), Some(&plain)), None);
        // The owner's rule of 23/11: a message the sender deleted keeps its content here, and quoting it
        // is not a refusal. The refusal that used to live here (`reply_source_deleted`) is gone.
        let mut deleted = source("text", "oi", false);
        deleted.deleted = true;
        assert_eq!(dispatch_refusal(Some("3EB0"), Some(&deleted)), None);
    }

    #[test]
    fn an_explicit_send_that_quotes_a_deleted_message_goes_out_without_the_quote() {
        // The reviewed rule: the send is never refused for a deletion, and it never re-publishes what the
        // author deleted. The sentence is the one the caller reads on the result.
        let mut deleted = source("text", "oi", false);
        deleted.deleted = true;
        assert_eq!(dispatch_refusal(Some("3EB0"), Some(&deleted)), None, "the send still goes out");
        assert_eq!(
            quote_decision(Some(&deleted)),
            Quote::Drop("sent without the quote: the quoted message was deleted by its author"),
            "the operator is told what changed, in those words"
        );
        assert_eq!(quote_decision(Some(&deleted)), Quote::Drop(wa_whatsapp_outbox::QUOTE_DROPPED_DELETED));
        // Everything else keeps whatever quote it asked for.
        assert_eq!(quote_decision(None), Quote::Keep, "no reply source: nothing to quote");
        assert_eq!(quote_decision(Some(&source("text", "oi", false))), Quote::Keep);
        assert_eq!(quote_decision(Some(&source("image", "", false))), Quote::Keep, "a shape is a refusal, not a dropped quote");
    }

    #[test]
    fn a_reply_source_must_be_exact_plain_text_by_someone_else() {
        let code = |r: Option<Refusal>| r.map(|refusal| refusal.stored());
        assert_eq!(code(dispatch_refusal(Some("3EB0"), None)), Some("reply_source_not_indexed:3EB0".to_string()));
        assert_eq!(code(dispatch_refusal(Some("3EB0"), Some(&source("text", "oi", true)))), Some("reply_source_own:3EB0".to_string()));
        let mut unsupported = source("text", "oi", false);
        unsupported.unsupported = "view_once".into();
        assert_eq!(code(dispatch_refusal(Some("3EB0"), Some(&unsupported))), Some("reply_source_unsupported:3EB0".to_string()));
        assert_eq!(code(dispatch_refusal(Some("3EB0"), Some(&source("audio", "", false)))), Some("reply_source_not_plain_text:3EB0".to_string()));
        assert_eq!(code(dispatch_refusal(Some("3EB0"), Some(&source("text", "   ", false)))), Some("reply_source_not_plain_text:3EB0".to_string()));
    }

    #[test]
    fn a_refusal_names_the_message_it_is_about_and_a_bare_code_is_a_bare_code() {
        // The whole defect of 23/11 in one assertion: a refusal must say WHICH message, or the caller
        // has to hash every chat in the account to find out.
        let refusal = Refusal { code: "reply_source_own", about: "3EB0ABCD".into() };
        assert_eq!(refusal.stored(), "reply_source_own:3EB0ABCD");
        assert_eq!(Refusal { code: "bad_chat", about: String::new() }.stored(), "bad_chat");
        // `retryable` reads the code at the head, never the id after it.
        assert!(!retryable(&refusal.stored()));
    }
}
