//! One property, over the shapes the index really stores: a `chat` a search hit hands back is a chat
//! every other question accepts.
//!
//! The index writes a record under the chat string the protocol (or a history sync) gave it, and
//! `hit_json` copies that string into the hit verbatim. A hit is therefore usable only if the same
//! value validates as the `chat` of `whatsapp_read` / `whatsapp_media` / `whatsapp_reactions` /
//! `whatsapp_download` / `whatsapp_backfill` / `whatsapp_search` and as the `chat` of a
//! `whatsapp_send` - and only if `Chat::jid()` reproduces it byte for byte, because that string is
//! also the kv prefix the record lives under (`ix/m/{chat}/…`, `ix/s/{sender}/…`). A parse that
//! accepted a chat but normalized it would answer "not_indexed" for a message the index just found.
//!
//! The live shape this file exists for (07/11): an older group is named
//! `9999999999999-9999999999@g.us` (creator phone, hyphen, creation epoch), and every tool refused it
//! as `bad_chat` while `whatsapp_search` kept returning hits that named it.

use wa_whatsapp_index as seam;
use wa_whatsapp_outbox::Chat;

/// Every chat shape the index can store: the address families the protocol addresses a chat by, and
/// the two spellings of a group id. Ranges, not one sample, because the rule is about shape (a digit
/// run, one hyphen) and not about the lengths WhatsApp happens to use today.
fn stored_chats() -> Vec<String> {
    let mut chats = Vec::new();
    // A person: the phone-number server (11-15 digits) and the hidden LID identity.
    for digits in [8usize, 11, 12, 13, 15, 16, 20] {
        let user = "9".repeat(digits);
        chats.push(format!("{user}@s.whatsapp.net"));
        chats.push(format!("{user}@lid"));
    }
    // A modern group: `120363` + millis-ish digits, and the plain digit runs a sync may hand over.
    for digits in [6usize, 12, 15, 18] {
        chats.push(format!("{}{}@g.us", "120363", "0".repeat(digits)));
    }
    // A legacy group: creator phone, one hyphen, creation epoch. The exact live value first, then the
    // cross-product of the lengths a creator phone (10-15) and an epoch (10-13) can have.
    chats.push("9999999999999-9999999999@g.us".to_string());
    for creator in [1usize, 10, 11, 13, 15] {
        for epoch in [1usize, 10, 11, 13] {
            chats.push(format!("{}-{}0@g.us", "9".repeat(creator), "1".repeat(epoch - 1)));
        }
    }
    chats
}

/// One request per operation, all naming `chat`, as the tool builds it before validation.
fn requests_naming(chat: &str) -> Vec<(seam::Op, seam::Request)> {
    let base = |op: &str| seam::Request { op: op.to_string(), chat: Some(chat.to_string()), ..Default::default() };
    vec![
        (seam::Op::Search, base("search")),
        (seam::Op::Read, base("read")),
        (seam::Op::Backfill, base("backfill")),
        (seam::Op::Reactions, seam::Request { id: Some("3EB0ABCDEF".into()), ..base("reactions") }),
        (seam::Op::Media, seam::Request { id: Some("3EB0ABCDEF".into()), ..base("media") }),
        (seam::Op::Download, seam::Request { id: Some("3EB0ABCDEF".into()), ..base("download") }),
    ]
}

#[test]
fn every_chat_a_search_hit_can_name_is_accepted_by_every_other_question() {
    let chats = stored_chats();
    assert!(chats.len() >= 30, "the generator covers the families, not one sample");
    assert!(chats.iter().any(|chat| chat == "9999999999999-9999999999@g.us"), "the live shape is in the set");
    for chat in &chats {
        // The chat the index stored is the chat `Chat::jid()` gives back: same bytes, same kv prefix.
        let parsed = Chat::parse(chat).unwrap_or_else(|refusal| panic!("{chat}: {}", refusal.detail));
        assert_eq!(&parsed.jid(), chat, "{chat}: parse must not rewrite a stored chat");

        // Every index question that takes a chat accepts the hit's chat (and keeps it unchanged).
        for (op, request) in requests_naming(chat) {
            let verified = request
                .validate()
                .unwrap_or_else(|refusal| panic!("{} {chat}: {}", op.tool(), refusal.detail));
            assert_eq!(verified.chat.as_ref().map(Chat::jid).as_deref(), Some(chat.as_str()), "{} {chat}", op.tool());
            // The component re-validates the payload it took from the queue; the round trip through
            // the wire must not change the chat either.
            let back = seam::Request::decode(&verified.to_request().encode()).expect("payload");
            assert_eq!(back.validate().expect("revalidated").chat.as_ref().map(Chat::jid).as_deref(), Some(chat.as_str()));
        }

        // `from` is the same exact-JID rule (a search may narrow by sender).
        let from = seam::Request { op: "search".into(), q: Some("x".into()), from: Some(chat.clone()), ..Default::default() };
        assert_eq!(from.validate().expect("from").from.map(|chat| chat.jid()).as_deref(), Some(chat.as_str()));

        // And the send path: a chat the index reports is a chat the agent may answer.
        let send = wa_whatsapp_outbox::Request {
            chat: chat.clone(),
            text: "oi".into(),
            reply_to: None,
            mentions: Vec::new(),
        };
        let verified = send.validate().unwrap_or_else(|refusal| panic!("send {chat}: {}", refusal.detail));
        assert_eq!(verified.chat.jid(), *chat);
        // Mentions are the same rule without the group allowance: a group is never a mention, but a
        // person chat is a mention exactly as the index spells it.
        if !parsed.is_group() {
            let mut mention = send;
            mention.mentions = vec![chat.clone()];
            assert_eq!(mention.validate().expect("mention").mentions[0].jid(), *chat);
        } else {
            let mut mention = send;
            mention.mentions = vec![chat.clone()];
            assert_eq!(mention.validate().unwrap_err().code, "bad_mention");
        }
    }
}

#[test]
fn an_older_group_id_is_the_legacy_hyphen_form_and_nothing_else_is() {
    // The hyphen is a group's, and only between two digit runs: the same string on a person's server
    // is not a phone number, and it is not an index shape either (nothing in `stored_chats()` has it).
    for chat in [
        "9999999999999-9999999999@s.whatsapp.net",
        "9999999999999-9999999999@lid",
        "9999999999999-9999999999@c.us",
        "1-2-3@g.us",
        "9999999999999-@g.us",
        "-9999999999@g.us",
    ] {
        assert!(!stored_chats().iter().any(|stored| stored == chat), "the generator must not claim {chat}");
        assert_eq!(Chat::parse(chat).unwrap_err().code, "bad_chat", "{chat}");
        let read = seam::Request { op: "read".into(), chat: Some(chat.into()), ..Default::default() };
        assert_eq!(read.validate().unwrap_err().code, "bad_chat", "{chat}");
    }
    // The legacy spelling of the phone server is accepted and normalized (never a fourth kind of chat),
    // which is why it is not in the generator: the index stores `s.whatsapp.net`.
    let legacy = Chat::parse("5511999999999@c.us").expect("c.us is a phone chat");
    assert_eq!(legacy.jid(), "5511999999999@s.whatsapp.net");
}
