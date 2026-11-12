//! One message, as a model reads it.
//!
//! The index answers with records; a model reads answers. This module is the one place that turns a
//! [`Record`] into the object a tool answer carries, so a search hit and a thread read cannot drift
//! into two shapes for the same message (2026-11-11: a session asked to send a message to a person by
//! name had no name to resolve, and the shapes it did get carried a JID where it expected a human).
//!
//! What the shape says, and what it refuses to invent:
//!
//! * `at` (Unix ms), `at_local` (`YYYY-MM-DD HH:MM`, the account's zone) and `at_iso` (RFC 3339,
//!   UTC). The zone is fixed to `-03:00`: it is the zone the operator's account is set to, it has had
//!   no DST since 2019, and a component has no clock configuration to consult. A wrong-by-an-hour
//!   local time would be worse than a stated one, so the offset is in the field name of the docs.
//! * `from` is `{jid, name, own}`: the JID is the address the index stored, `name` is the push name
//!   the envelope carried (empty when it carried none - never the JID passed off as a name).
//! * `text` is a snippet ([`seam::MAX_TEXT_CHARS`]) and `text_truncated` says whether the index holds
//!   more; when it does, `full` is the exact call that returns the whole stored text
//!   (`whatsapp_message`), so a long message is a pointer and never a silent cut.
//! * `reply_to` is `{id, quote}`: the id of the quoted message and, when the quoted message is in the
//!   index, its snippet. A quote the index has not seen keeps its id and an empty `quote`, which is
//!   honest about a partial history instead of pretending there was nothing quoted.
//! * `media` is metadata only (`kind`, `name`, `size`, `caption`, `mime`): no bytes, no media key.
//! * `edited`/`deleted` are the source mutations, and a revoked message carries no text at all (the
//!   record was redacted before this point).
//!
//! Nothing here reads message text into a log line, and nothing here makes a name up: every string is
//! either stored on the record or a stable word.

use crate::record::Record;
use wa_whatsapp_index as seam;

/// The account's zone offset from UTC, in seconds. America/Sao_Paulo, no DST since 2019.
const LOCAL_OFFSET_SECONDS: i64 = -3 * 3600;

/// Days since 1970-01-01 -> (year, month, day), and seconds since midnight -> (hour, minute, second).
fn parts(ms: i64, offset_seconds: i64) -> ((i64, u32, u32), (i64, i64, i64)) {
    let secs = ms.div_euclid(1000) + offset_seconds;
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    (crate::alerts::civil(days), (rem / 3600, (rem % 3600) / 60, rem % 60))
}

/// `YYYY-MM-DDTHH:MM:SSZ`, UTC: the rendering that sorts, compares and never depends on a zone.
pub fn iso(ms: i64) -> String {
    let ((y, m, d), (h, mi, s)) = parts(ms, 0);
    format!("{y:04}-{m:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z")
}

/// `YYYY-MM-DD HH:MM` in the account's zone (`-03:00`), which is what the operator reads on a phone.
pub fn local(ms: i64) -> String {
    let ((y, m, d), (h, mi, _)) = parts(ms, LOCAL_OFFSET_SECONDS);
    format!("{y:04}-{m:02}-{d:02} {h:02}:{mi:02}")
}

/// The media metadata a read or a search hit carries: enough to decide whether to ask for the file,
/// and never the bytes.
fn media(record: &Record) -> serde_json::Value {
    let media = match &record.media {
        Some(media) => media,
        None => return serde_json::Value::Null,
    };
    serde_json::json!({
        "kind": media.kind,
        // `name` is the field a reader looks for; `filename` stays beside it for the older readers.
        "name": media.filename,
        "filename": media.filename,
        "size": media.size,
        "caption": record.text,
        "mime": media.mime,
        "duration_s": media.duration_s,
        "downloadable": media.downloadable,
        "view_once": media.view_once,
    })
}

/// One message as a tool answer carries it.
///
/// `quote` is the snippet of the message this one replies to, when the caller could load it; `None`
/// means "not resolved here", which is written as an empty `quote` rather than omitted, so a reader
/// can tell "the index does not have it" from "this is not a reply".
pub fn message(record: &Record, quote: Option<&str>) -> serde_json::Value {
    let snippet = record.snippet(seam::MAX_TEXT_CHARS);
    let mut view = serde_json::json!({
        "id": record.id,
        "chat": record.chat,
        "kind": record.kind,
        // The JID fields the earlier answers carried, unchanged: an existing reader keeps working.
        "ts": record.ts,
        "sender": record.sender,
        "sender_name": record.push_name,
        // The shape a model reads: when (three ways), who, what.
        "at": record.ts,
        "at_local": local(record.ts),
        "at_iso": iso(record.ts),
        "from": { "jid": record.sender, "name": record.push_name, "own": record.own },
        "text": snippet,
        "text_truncated": snippet.chars().count() < record.body().chars().count(),
    });
    if view["text_truncated"] == serde_json::Value::Bool(true) {
        // Long text is a pointer: the exact call that returns the stored bytes.
        view["full"] = serde_json::json!({
            "tool": "whatsapp_message",
            "chat": record.chat,
            "id": record.id,
            "chars": record.body().chars().count(),
        });
    }
    if !record.quoted.is_empty() {
        view["reply_to"] = serde_json::json!({
            "id": record.quoted,
            "quote": quote.unwrap_or("").chars().take(seam::MAX_TEXT_CHARS).collect::<String>(),
        });
    }
    let media = media(record);
    if !media.is_null() {
        view["media"] = media;
    }
    if !record.mentions.is_empty() {
        view["mentions"] = serde_json::Value::Array(
            record.mentions.iter().take(seam::MAX_LISTED).map(|jid| serde_json::Value::String(jid.clone())).collect(),
        );
    }
    if record.edited {
        view["edited"] = serde_json::Value::Bool(true);
    }
    if record.deleted {
        view["deleted"] = serde_json::Value::Bool(true);
    }
    if record.from_history() {
        view["source"] = serde_json::Value::String(crate::record::SOURCE_HISTORY.to_string());
    }
    if !record.unsupported.is_empty() {
        view["unsupported"] = serde_json::Value::String(record.unsupported.clone());
    }
    if record.kind == "reaction" && !record.emoji.is_empty() {
        view["emoji"] = serde_json::Value::String(record.emoji.clone());
        view["target"] = serde_json::Value::String(record.target.clone());
    }
    if record.kind == "edit" || record.kind == "delete" {
        view["target"] = serde_json::Value::String(record.target.clone());
    }
    view
}

/// The header a thread read and a search answer start with: which chat this is, in words, and how to
/// read the page under it.
///
/// `name` is the nickname the index observed, empty when it observed none (`name_source` then says
/// `jid`); `unread` is always `null` with `unread_reason: not_indexed`, because this node's index
/// carries no read receipts and a made-up unread count would be a claim nobody can check.
pub fn chat_header(
    chat: &str,
    group: bool,
    name: &str,
    name_source: &str,
    participants: Vec<serde_json::Value>,
    messages: u32,
) -> serde_json::Value {
    let mut header = serde_json::json!({
        "chat": chat,
        "type": if group { "group" } else { "person" },
        "name": name,
        "name_source": name_source,
        "messages": messages,
        "unread": serde_json::Value::Null,
        "unread_reason": "not_indexed",
    });
    if group {
        header["participants"] = serde_json::Value::Array(participants);
    }
    header
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(kind: &str, text: &str) -> Record {
        Record {
            chat: "5511999999999@s.whatsapp.net".into(),
            id: "3EB0A".into(),
            sender: "5511999999999@s.whatsapp.net".into(),
            ts: 1_760_000_000_000,
            kind: kind.into(),
            text: text.into(),
            push_name: "Laura".into(),
            ..Default::default()
        }
    }

    #[test]
    fn a_time_is_stated_three_ways_and_the_local_one_is_the_accounts_zone() {
        assert_eq!(iso(0), "1970-01-01T00:00:00Z");
        // 2026-11-11T12:00:00Z is 09:00 in the account's zone (-03:00, no DST).
        let ms = 1_794_398_400_000;
        assert_eq!(iso(ms), "2026-11-11T12:00:00Z");
        assert_eq!(local(ms), "2026-11-11 09:00");
        // A message at 02:00 UTC is the *previous* day locally, which is the case a naive
        // "subtract three hours from the date" gets wrong.
        assert_eq!(iso(1_794_362_400_000), "2026-11-11T02:00:00Z");
        assert_eq!(local(1_794_362_400_000), "2026-11-10 23:00");
    }

    #[test]
    fn a_message_carries_who_when_and_what_in_the_one_shape() {
        let view = message(&record("text", "bom dia"), None);
        assert_eq!(view["from"]["jid"], "5511999999999@s.whatsapp.net");
        assert_eq!(view["from"]["name"], "Laura");
        assert_eq!(view["from"]["own"], false);
        assert_eq!(view["at"], 1_760_000_000_000_i64);
        assert!(view["at_iso"].as_str().unwrap().ends_with('Z'));
        assert_eq!(view["text"], "bom dia");
        assert_eq!(view["text_truncated"], false);
        assert!(view.get("full").is_none());
        // The keys the older answers carried stay, so a reader of the old shape keeps working.
        assert_eq!(view["ts"], view["at"]);
        assert_eq!(view["sender_name"], "Laura");
    }

    #[test]
    fn a_long_message_is_a_pointer_to_its_stored_text() {
        let long = "a".repeat(seam::MAX_TEXT_CHARS + 40);
        let view = message(&record("text", &long), None);
        assert_eq!(view["text_truncated"], true);
        assert_eq!(view["full"]["tool"], "whatsapp_message");
        assert_eq!(view["full"]["chat"], "5511999999999@s.whatsapp.net");
        assert_eq!(view["full"]["chars"], long.chars().count());
    }

    #[test]
    fn a_reply_keeps_its_quote_and_an_unknown_quote_is_empty_not_absent() {
        let mut reply = record("text", "claro");
        reply.quoted = "3EB0ORIGINAL".into();
        let with_quote = message(&reply, Some("posso ligar?"));
        assert_eq!(with_quote["reply_to"]["id"], "3EB0ORIGINAL");
        assert_eq!(with_quote["reply_to"]["quote"], "posso ligar?");
        // The index never saw the quoted message (a partial history): the id is kept, the quote is
        // empty, and neither is invented.
        let without = message(&reply, None);
        assert_eq!(without["reply_to"]["id"], "3EB0ORIGINAL");
        assert_eq!(without["reply_to"]["quote"], "");
    }

    #[test]
    fn media_is_metadata_with_a_name_a_size_and_the_caption() {
        let mut photo = record("image", "o recibo");
        photo.media = Some(crate::record::Media {
            kind: "image".into(),
            mime: "image/jpeg".into(),
            filename: "recibo.jpg".into(),
            size: 48_213,
            downloadable: true,
            ..Default::default()
        });
        let view = message(&photo, None);
        assert_eq!(view["media"]["kind"], "image");
        assert_eq!(view["media"]["name"], "recibo.jpg");
        assert_eq!(view["media"]["size"], 48_213);
        assert_eq!(view["media"]["caption"], "o recibo");
        // No bytes and no key in an answer.
        assert!(view["media"].get("media_key").is_none());
    }

    #[test]
    fn a_deleted_message_says_so_and_carries_no_text() {
        let mut gone = record("text", "segredo");
        gone.deleted = true;
        gone.text = String::new();
        let view = message(&gone, None);
        assert_eq!(view["deleted"], true);
        assert_eq!(view["text"], "");
    }

    #[test]
    fn the_header_names_the_chat_and_never_invents_an_unread_count() {
        let header = chat_header("120@g.us", true, "Família", "group_subject", vec![], 7);
        assert_eq!(header["type"], "group");
        assert_eq!(header["name"], "Família");
        assert_eq!(header["unread"], serde_json::Value::Null);
        assert_eq!(header["unread_reason"], "not_indexed");
        let person = chat_header("5511@s.whatsapp.net", false, "", "jid", vec![], 1);
        assert_eq!(person["type"], "person");
        assert!(person.get("participants").is_none(), "a person has no participant list");
    }
}
