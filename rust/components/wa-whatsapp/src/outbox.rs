//! The outbox's decisions that need no host: what a verified request becomes on the wire, and which
//! failures are worth another attempt.
//!
//! The queue contract, the payload and the refusals live in `wa-whatsapp-outbox` (shared with the
//! node, `rust/wa-host/src/whatsapp_send.rs`). What is left is the shape of the WhatsApp message this
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

#[cfg(test)]
mod tests {
    use super::*;
    use wa_whatsapp_outbox::{Chat, Request, Verified};

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
        for jid in ["72103978127547@lid", "5511999999999@s.whatsapp.net", "120363000000000001@g.us"] {
            let chat = Chat::parse(jid).expect(jid);
            assert_eq!(chat.jid(), jid);
            let parsed: whatsapp_rust::Jid = chat.jid().parse().expect("the library parses it");
            assert_eq!(parsed.to_string(), jid);
        }
    }

    #[test]
    fn a_refusal_is_never_retried_and_a_transport_failure_is() {
        assert!(!retryable("bad_chat"));
        assert!(!retryable("not_logged_in"));
        assert!(retryable("websocket closed"));
        assert!(retryable("timeout"));
    }
}
