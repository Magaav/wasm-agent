//! The one place this component turns a chat string into a typed chat.
//!
//! Two typed shapes exist on the query paths, and before this module they were reached from three
//! different places with three different rules:
//!
//! * [`seam::Chat`] (`wa-whatsapp-index` -> `wa-whatsapp-outbox::Chat`) - what a query names. The
//!   producer (the node's `host.whatsapp_read`/`_media`/`_download`/`_backfill`) and this component
//!   both reach it through `seam::Request::validate`, so the rule is already shared there.
//! * [`whatsapp_rust::Jid`] - what the protocol library is handed (`client.send_message`,
//!   `client.fetch_message_history`, the audio queue's persisted job). A `Jid` parse is *more*
//!   permissive than the chat rule (it accepts `user:device@…`, `@broadcast`, `@newsletter`), so a
//!   string the query rule refuses used to reach the library anyway on the send, backfill and restart
//!   paths: a `bad_chat` one layer deeper, or a request the phone could not answer.
//!
//! So there is exactly one rule ([`accept`], which *is* the seam's `Chat::parse`) and exactly one
//! conversion ([`jid`]) that every chat-to-library step in the component goes through. The read,
//! media, download, reactions and search paths never parse a chat themselves: they take the seam's
//! [`seam::Chat`] and use [`seam::Chat::jid`] as the index key spelling. `read`/`media` therefore
//! accept exactly what the node accepted, because it is the same function, and a chat this component
//! stored ([`storable`]) is always one the rule accepts.
//!
//! A legacy group id (`<creator phone>-<creation epoch>@g.us`, what an older group is really called
//! and what a `whatsapp_search` hit names) is part of that one rule: the fix of 07/11 put it in
//! `Chat::parse` (the seam), and this module is why no call site can disagree with it again.
use wa_whatsapp_index as seam;
use wa_whatsapp_outbox::Chat;

/// The one chat rule, in this component's refusal type (the seam's), so a caller has one word:
/// `bad_chat` for a shape that is not an exact JID and `unsupported_chat` for a server the client
/// cannot address. Exactly [`wa_whatsapp_outbox::Chat::parse`]: nothing is added and nothing is
/// loosened here, which is what makes "the node accepted it, the component refused it" impossible.
pub fn accept(chat: &str) -> Result<Chat, seam::Refusal> {
    Chat::parse(chat).map_err(|refusal| seam::Refusal::new(refusal.code, refusal.detail))
}

/// The one conversion from a chat string to the library's typed JID.
///
/// The chat rule decides first, so the accept language is exactly the seam's; the library's parse is
/// only the spelling step (and its `Display` round trips the same id, which the tests pin). A
/// library refusal after the rule accepted the chat is still reported as `bad_chat` - the same word
/// the query path uses - because the alternative is a silent drop.
pub fn jid(chat: &str) -> Result<whatsapp_rust::Jid, String> {
    let accepted = accept(chat).map_err(|refusal| refusal.code.to_string())?;
    accepted.jid().parse().map_err(|_| "bad_chat".to_string())
}

/// The canonical spelling of a chat when the rule accepts it, `None` when it does not: the form the
/// index keys and answers with (`c.us` is the phone server's legacy spelling and normalizes to
/// `s.whatsapp.net`; nothing else is rewritten).
pub fn canonical(chat: &str) -> Option<String> {
    accept(chat).ok().map(|accepted| accepted.jid())
}

/// What the index stores for a chat: the canonical spelling when the rule accepts it, the string it
/// was given otherwise.
///
/// A message is indexed whatever its chat is called (dropping a received message because its chat
/// is odd would be the silent loss this component must not have), but every chat a search hit can
/// name that the protocol gave us in a spelling the rule knows is stored in the spelling a query
/// accepts - so a hit is always a pointer to a readable thread.
pub fn storable(chat: &str) -> String {
    canonical(chat).unwrap_or_else(|| chat.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every shape a chat can be named by, plus its refused neighbours: the corpus the one rule and
    /// one conversion are both measured against.
    const ACCEPTED: [&str; 9] = [
        // a person: phone number, LID, and the phone server's legacy spelling
        "5511999999999@s.whatsapp.net",
        "5511999999999@c.us",
        "72103978127547@lid",
        // a group: the modern id and the legacy `<creator phone>-<creation epoch>` id a search hit
        // names (the 07/11 finding)
        "120363000000000001@g.us",
        "9999999999999-9999999999999@g.us",
        "9999999999999-1@g.us",
        "1-9999999999999@g.us",
        // a value the caller padded: the rule trims, and the canonical form is unpadded
        " 5511999999999@lid ",
        // the longest user part the rule takes
        "12345678901234567890123456789012@lid",
    ];

    const REFUSED: [&str; 20] = [
        "",
        "   ",
        "5511999999999",
        "@lid",
        "55a1@lid",
        "5511:12@s.whatsapp.net",
        "5511 999@lid",
        "5511\t999@lid",
        // the hyphen belongs to a group id and nowhere else
        "9999999999999-9999999999@s.whatsapp.net",
        "9999999999999-9999999999@lid",
        "1-2-3@g.us",
        "-1@g.us",
        "1-@g.us",
        "1--2@g.us",
        "12a-3@g.us",
        // servers the client cannot address
        "status@broadcast",
        "120363000000000001@newsletter",
        "123@bot",
        // too long: user part, and the whole string
        "123456789012345678901234567890123@lid",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa@lid",
    ];

    #[test]
    fn the_one_rule_accepts_exactly_what_the_seam_accepts() {
        for text in ACCEPTED.iter().chain(REFUSED.iter()) {
            let mine = accept(text);
            let seam = Chat::parse(text);
            assert_eq!(mine.is_ok(), seam.is_ok(), "{text:?}");
            match (mine, seam) {
                (Ok(mine), Ok(seam)) => assert_eq!(mine.jid(), seam.jid(), "{text:?}"),
                (Err(mine), Err(seam)) => assert_eq!(mine.code, seam.code, "{text:?}"),
                _ => unreachable!(),
            }
        }
    }

    #[test]
    fn the_one_conversion_accepts_the_same_strings_and_names_the_same_chat() {
        for text in ACCEPTED.iter() {
            let jid = jid(text).unwrap_or_else(|code| panic!("{text:?} refused as {code}"));
            // The library's Display round trips the exact id the index keys on, so a hit's chat value
            // survives the trip to the client unchanged.
            assert_eq!(jid.to_string(), canonical(text).expect("accepted"), "{text:?}");
        }
        for text in REFUSED.iter() {
            // The word is the seam's (`bad_chat` or `unsupported_chat`), never a library message and
            // never a silent drop.
            assert_eq!(jid(text).unwrap_err(), accept(text).unwrap_err().code, "{text:?}");
        }
    }

    #[test]
    fn a_legacy_group_id_is_a_chat_on_the_send_backfill_and_restart_paths_too() {
        // The exact value from the live finding: accepted by the rule, by the conversion, stored as
        // itself, and (crucially) the library parses it, so `send_message`/`fetch_message_history`
        // and a queued audio job recovered after a restart all address the same chat.
        let legacy = "9999999999999-9999999999@g.us";
        assert!(accept(legacy).unwrap().is_group());
        assert_eq!(jid(legacy).unwrap().to_string(), legacy);
        assert_eq!(storable(legacy), legacy);
        // Its refused neighbours stay refused: two hyphens, an empty half, a hyphen on a person.
        for bad in ["1-2-3@g.us", "-1@g.us", "1-@g.us", "9999999999999-9999999999@s.whatsapp.net"] {
            assert_eq!(jid(bad).unwrap_err(), "bad_chat", "{bad}");
            assert_eq!(storable(bad), bad, "a message is still indexed under the chat it arrived on");
        }
    }

    #[test]
    fn a_stored_chat_is_a_chat_a_query_accepts() {
        for text in ACCEPTED.iter() {
            let stored = storable(text);
            assert!(accept(&stored).is_ok(), "{text:?} stored as {stored:?}");
            assert_eq!(stored, canonical(text).expect("accepted"));
        }
        // `c.us` is the phone server's legacy spelling: stored as the spelling a query names.
        assert_eq!(storable("5511999999999@c.us"), "5511999999999@s.whatsapp.net");
        // A shape the rule refuses is kept verbatim rather than dropped or guessed at.
        assert_eq!(storable("5511999999999:12@s.whatsapp.net"), "5511999999999:12@s.whatsapp.net");
    }
}
