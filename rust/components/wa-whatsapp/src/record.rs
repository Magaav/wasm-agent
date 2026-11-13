//! One received WhatsApp message, as the index keeps it - every kind, not only the ones the
//! transcription pipeline cares about.
//!
//! The Go connector's `messages` row kept `chat, id, sender, body, sent, media_kind, media_text` and
//! called everything that was not text or an image `unsupported_non_audio_message`. The owner's
//! requirement for the new bridge (06/11) is that *every* message is indexed and queryable: text,
//! image, video, audio/voice, document (filename + mime + size + caption), sticker, location, contact
//! card, poll, and the source mutations (edits, deletions, reactions) as events. This module turns one
//! inbound `wa::Message` plus its envelope into that record; it is pure, so a fake client is just a
//! hand-built proto message (`tests` below).
//!
//! Two rules the record keeps, because they are the reason it is not simply a protobuf copy:
//!
//! * **Metadata, not content.** The record holds what a query needs to answer and to point at the
//!   media later (mime, filename, size, sha256, duration, page count, and the `direct_path`/`media_key`
//!   pair a re-download needs) - not the bytes, not the thumbnail, not the vcard body.
//! * **What must not be kept is not kept.** A view-once or ephemeral message is indexed as a fact
//!   (it existed, from whom, which kind) with no text and no media keys, so it can never be read or
//!   downloaded here.
//!
//! Never a log line: nothing in this module logs, and no caller may log `text`, `transcript` or `ocr`.
use serde::{Deserialize, Serialize};
use whatsapp_rust::waproto::whatsapp as wap;
use wacore::proto_helpers::MessageExt;

/// Longest text one record keeps, in characters. WhatsApp's own text bound is 65 536; the index is a
/// search surface, so it keeps enough to answer with a snippet and to tokenize a normal message, and
/// stops there instead of turning one long message into a kv-sized blob.
pub const MAX_TEXT: usize = 4_096;
/// The message arrived on the live stream (a notification while connected).
///
/// `source` is the one field that says *where* a record came from: a live message and the same message
/// re-delivered by a history sync are the same record (the id is the key), so the first writer keeps
/// the row and this field is what tells an operator, and a query, which of the two it was.
pub const SOURCE_LIVE: &str = "live";
/// The message came out of a history sync (the past, backfilled from the protocol).
pub const SOURCE_HISTORY: &str = "history";
/// Largest media the pipeline ever downloaded (the Go connector's `maxMediaBytes`), so a bigger one is
/// recorded as `media_too_large` rather than promised as downloadable.
pub const MAX_MEDIA_BYTES: u64 = 20 * 1024 * 1024;
/// Most mentions one record keeps.
pub const MAX_MENTIONS: usize = 64;
/// Most contact-card entries one record keeps.
pub const MAX_CONTACTS: usize = 8;
/// Most poll options one record keeps.
pub const MAX_OPTIONS: usize = 24;

/// The media of one message: what it is, and the pair a later download needs.
///
/// `media_key` and `direct_path` are kept because WhatsApp's CDN needs both to fetch a blob, and the
/// component's query lane is the only place that can still decrypt it hours later (`DownloadParams`).
/// Neither is ever returned in an answer (`docs/SERVICE-COMPONENTS.md`).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Media {
    /// `image` | `video` | `audio` | `voice` | `document` | `sticker`.
    pub kind: String,
    pub mime: String,
    pub filename: String,
    pub size: u64,
    /// The plaintext hash WhatsApp published (hex), the handle a caller quotes.
    pub sha256: String,
    /// The encrypted-blob hash (hex); kept for a re-download that must prove the ciphertext.
    pub enc_sha256: String,
    pub duration_s: u32,
    pub pages: u32,
    pub width: u32,
    pub height: u32,
    pub direct_path: String,
    /// Hex of the 32-byte media key.
    pub media_key: String,
    pub media_key_ts: i64,
    pub view_once: bool,
    pub animated: bool,
    /// True when the blob can be fetched: a direct path and a media key were both present.
    pub downloadable: bool,
}

/// A shared location: the coordinates are the message, the labels are what a human search uses.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Place {
    pub lat: f64,
    pub lng: f64,
    pub name: String,
    pub address: String,
    pub live: bool,
}

/// One entry of a contact card. The vcard's own body is not kept: a name and the phone numbers it
/// names are what a query can answer with.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Contact {
    pub name: String,
    pub phones: Vec<String>,
}

/// A poll: its question and its options (the votes are other messages).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Poll {
    pub name: String,
    pub options: Vec<String>,
    pub selectable: u32,
}

/// One indexed message or event.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Record {
    pub chat: String,
    pub id: String,
    pub sender: String,
    /// The sender's other address (PN<->LID) when the envelope carried it: the same author proof the
    /// revive/fence logic uses, kept so a query can answer "who" the same way twice.
    pub sender_alt: String,
    pub own: bool,
    pub group: bool,
    /// The message's own timestamp, Unix ms.
    pub ts: i64,
    /// When this node saw it, Unix ms.
    pub received: i64,
    /// `text` | `image` | `video` | `audio` | `voice` | `document` | `sticker` | `location` |
    /// `contact` | `poll` | `reaction` | `edit` | `delete` | `other`.
    pub kind: String,
    /// The body, or the caption of a media message.
    pub text: String,
    /// `live` or `history`: where this record came from (`SOURCE_LIVE` / `SOURCE_HISTORY`). A record
    /// written before this field existed reads back as `""`, which is a live message for every
    /// reader: an absent source must never look like a backfilled one.
    pub source: String,
    /// The id of the message this one quotes (a reply), or of the message an event acts on.
    pub quoted: String,
    pub mentions: Vec<String>,
    /// Push name of the sender when the envelope carried one (a group's subject is not this).
    pub push_name: String,
    /// The verified business name this record was told for its sender, when the wire carried one
    /// (`WebMessageInfo.verifiedBizName`, which only a history-sync entry has). It is the name WhatsApp
    /// itself shows for that account, which no push name and no address-book entry can stand in for - a
    /// query for "Padaria" has to find the bakery whose owner's own push name is a first name
    /// (index.rs folds it as the `profile` source).
    pub business: String,
    /// An event's target: the message a reaction/edit/delete names.
    pub target: String,
    /// A reaction's emoji. Empty means the reaction was *removed* (WhatsApp sends the same message
    /// with an empty text to take it back).
    pub emoji: String,
    pub edited: bool,
    pub edits: u32,
    pub deleted: bool,
    /// When the last edit/delete was applied, Unix ms (0 for a plain message).
    pub event_ts: i64,
    pub media: Option<Media>,
    pub place: Option<Place>,
    pub contacts: Vec<Contact>,
    pub poll: Option<Poll>,
    /// Text the transcription pipeline attached to this message (`speech.recognize`).
    pub transcript: String,
    /// Text an OCR pass attached to this message.
    pub ocr: String,
    /// `view_once`, `ephemeral_media_not_retained`, `media_too_large`, `unsupported_kind`, …: why this
    /// record is a fact rather than a readable message. Empty for a normal one.
    pub unsupported: String,
}

/// What the protocol layer knows about one inbound message: the envelope, not the content.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Envelope {
    pub chat: String,
    pub id: String,
    pub sender: String,
    pub sender_alt: String,
    pub own: bool,
    pub group: bool,
    pub ts: i64,
    pub received: i64,
    pub push_name: String,
    /// The verified business name the wire carried for this sender, when it carried one. WhatsApp puts
    /// it on the history-sync entry (`WebMessageInfo.verifiedBizName`) and not on the message itself
    /// (`Message` has no such field), so a live message leaves this empty: absent is what it is, and a
    /// guess would be a name nobody said.
    pub business: String,
}

impl Record {
    /// True when this record was backfilled from a history sync rather than received live.
    pub fn from_history(&self) -> bool {
        self.source == SOURCE_HISTORY
    }

    /// True for the rows that are a change to another message rather than a message of their own.
    pub fn is_event(&self) -> bool {
        matches!(self.kind.as_str(), "reaction" | "edit" | "delete")
    }

    /// The text a query answers with: the body, or what stands in for it (a document's filename, a
    /// location's label, a poll's question).
    pub fn body(&self) -> &str {
        if !self.text.is_empty() {
            return &self.text;
        }
        if let Some(media) = &self.media {
            if !media.filename.is_empty() {
                return &media.filename;
            }
        }
        if let Some(place) = &self.place {
            if !place.name.is_empty() {
                return &place.name;
            }
            return &place.address;
        }
        if let Some(poll) = &self.poll {
            return &poll.name;
        }
        if let Some(first) = self.contacts.first() {
            return &first.name;
        }
        if !self.transcript.is_empty() {
            return &self.transcript;
        }
        if !self.ocr.is_empty() {
            return &self.ocr;
        }
        ""
    }

    /// A bounded one-line snippet for an answer: never a newline, never the whole message.
    pub fn snippet(&self, max: usize) -> String {
        if self.deleted {
            return String::new();
        }
        one_line(self.body(), max)
    }

    /// Everything this record is searchable by: its text, a document's filename, the attachment's
    /// name, and any transcript/OCR text that was attached to it.
    pub fn searchable(&self) -> String {
        let mut out = String::with_capacity(self.text.len() + self.transcript.len() + 64);
        for part in [self.text.as_str(), self.transcript.as_str(), self.ocr.as_str()] {
            if !part.is_empty() {
                out.push_str(part);
                out.push(' ');
            }
        }
        if let Some(media) = &self.media {
            out.push_str(&media.filename);
            out.push(' ');
            out.push_str(&media.mime);
        }
        if let Some(place) = &self.place {
            out.push_str(&place.name);
            out.push(' ');
            out.push_str(&place.address);
        }
        if let Some(poll) = &self.poll {
            out.push_str(&poll.name);
            for option in &poll.options {
                out.push(' ');
                out.push_str(option);
            }
        }
        for contact in &self.contacts {
            out.push(' ');
            out.push_str(&contact.name);
        }
        out
    }

    /// The normalized tokens this record is indexed under (accent-folded, lowercase, deduplicated,
    /// bounded). Always includes the chat's user part and the sender's, so "messages from
    /// 5511…" style searches work without a separate query path.
    pub fn tokens(&self) -> Vec<String> {
        let mut tokens: Vec<String> = Vec::new();
        for token in tokenize(&self.searchable()) {
            if tokens.len() >= crate::index::MAX_TOKENS {
                break;
            }
            if !tokens.iter().any(|seen| seen == &token) {
                tokens.push(token);
            }
        }
        tokens
    }
}

/// Turn one inbound message into the record the index keeps. `message` is the message as it arrived:
/// wrappers (device-sent, ephemeral, view-once, document-with-caption, edited) are peeled here.
///
/// The chat is stored in the spelling the one rule accepts ([`crate::chat::storable`]): the index keys
/// and every answer that names a chat therefore use a value `whatsapp_read`/`_media`/`_download`/
/// `_backfill` accept, so a search hit is always a pointer to a chat a query can use (the 07/11
/// finding: a hit named a legacy group id the read path refused). A chat the rule does not know is
/// kept verbatim - a received message is never dropped because its address is odd.
pub fn from_message(envelope: &Envelope, message: &wap::Message) -> Record {
    let mut record = Record {
        chat: crate::chat::storable(&envelope.chat),
        id: envelope.id.clone(),
        sender: envelope.sender.clone(),
        sender_alt: envelope.sender_alt.clone(),
        own: envelope.own,
        group: envelope.group,
        ts: envelope.ts,
        received: envelope.received,
        push_name: envelope.push_name.clone(),
        business: envelope.business.clone(),
        source: SOURCE_LIVE.to_string(),
        ..Record::default()
    };
    let base = message.get_base_message();

    // The source mutations first: they are what a later read and a forever-unreadable message hinge on.
    if let Some(protocol) = base.protocol_message.as_option() {
        let target = protocol.key.as_option().and_then(|key| key.id.clone()).unwrap_or_default();
        match protocol.r#type {
            Some(wap::message::protocol_message::Type::REVOKE) => {
                record.kind = "delete".into();
                record.target = target;
                record.event_ts = record.ts;
                return record;
            }
            Some(wap::message::protocol_message::Type::MESSAGE_EDIT) => {
                record.kind = "edit".into();
                record.target = target;
                record.event_ts = record.ts;
                if let Some(edited) = protocol.edited_message.as_option() {
                    record.text = edit_text(edited);
                    record.quoted = context_of(edited).and_then(|c| c.stanza_id.clone()).unwrap_or_default();
                    record.mentions = mentions_of(edited);
                }
                return record;
            }
            other => {
                record.kind = "other".into();
                record.unsupported = match other {
                    Some(kind) => format!("protocol_{kind:?}").to_ascii_lowercase(),
                    None => "protocol_message".into(),
                };
                return record;
            }
        }
    }
    if let Some(reaction) = base.reaction_message.as_option() {
        record.kind = "reaction".into();
        record.target = reaction.key.as_option().and_then(|key| key.id.clone()).unwrap_or_default();
        // An empty text is a *removal*: the same actor taking the emoji back.
        record.emoji = reaction.text.clone().unwrap_or_default().chars().take(16).collect();
        record.event_ts = record.ts;
        return record;
    }

    // Text and wrappers.
    if let Some(text) = base.text_content() {
        record.kind = "text".into();
        record.text = bounded(text, MAX_TEXT);
    }
    if let Some(context) = context_of(base) {
        record.quoted = context.stanza_id.clone().filter(|id| !id.is_empty()).unwrap_or_default();
        record.mentions = context.mentioned_jid.iter().filter(|jid| !jid.is_empty()).take(MAX_MENTIONS).cloned().collect();
    }

    // The body kinds, in the order WhatsApp nests them.
    if let Some(image) = base.image_message.as_option() {
        record.kind = "image".into();
        record.media = Some(Media {
            kind: "image".into(),
            mime: text_of(&image.mimetype),
            size: image.file_length.unwrap_or(0),
            sha256: hex_of(&image.file_sha256),
            enc_sha256: hex_of(&image.file_enc_sha256),
            width: image.width.unwrap_or(0),
            height: image.height.unwrap_or(0),
            direct_path: text_of(&image.direct_path),
            media_key: hex_of(&image.media_key),
            media_key_ts: image.media_key_timestamp.unwrap_or(0),
            view_once: image.view_once.unwrap_or(false),
            filename: format!("IMG-{}.{}", short_id(&record.id), extension(&text_of(&image.mimetype))),
            ..Media::default()
        });
        record.text = bounded(&text_of(&image.caption), MAX_TEXT);
    } else if let Some(video) = base.video_message.as_option() {
        record.kind = "video".into();
        record.media = Some(Media {
            kind: "video".into(),
            mime: text_of(&video.mimetype),
            size: video.file_length.unwrap_or(0),
            sha256: hex_of(&video.file_sha256),
            enc_sha256: hex_of(&video.file_enc_sha256),
            duration_s: video.seconds.unwrap_or(0),
            width: video.width.unwrap_or(0),
            height: video.height.unwrap_or(0),
            direct_path: text_of(&video.direct_path),
            media_key: hex_of(&video.media_key),
            media_key_ts: video.media_key_timestamp.unwrap_or(0),
            view_once: video.view_once.unwrap_or(false),
            filename: format!("VID-{}.{}", short_id(&record.id), extension(&text_of(&video.mimetype))),
            ..Media::default()
        });
        record.text = bounded(&text_of(&video.caption), MAX_TEXT);
    } else if let Some(audio) = base.audio_message.as_option() {
        let voice = audio.ptt.unwrap_or(false);
        record.kind = if voice { "voice".into() } else { "audio".into() };
        record.media = Some(Media {
            kind: if voice { "voice".into() } else { "audio".into() },
            mime: text_of(&audio.mimetype),
            size: audio.file_length.unwrap_or(0),
            sha256: hex_of(&audio.file_sha256),
            enc_sha256: hex_of(&audio.file_enc_sha256),
            duration_s: audio.seconds.unwrap_or(0),
            direct_path: text_of(&audio.direct_path),
            media_key: hex_of(&audio.media_key),
            media_key_ts: audio.media_key_timestamp.unwrap_or(0),
            view_once: audio.view_once.unwrap_or(false),
            filename: format!("{}-{}.{}", if voice { "PTT" } else { "AUD" }, short_id(&record.id), extension(&text_of(&audio.mimetype))),
            ..Media::default()
        });
    } else if let Some(document) = base.document_message.as_option() {
        record.kind = "document".into();
        let filename = text_of(&document.file_name);
        record.media = Some(Media {
            kind: "document".into(),
            mime: text_of(&document.mimetype),
            filename: if filename.is_empty() {
                format!("DOC-{}.{}", short_id(&record.id), extension(&text_of(&document.mimetype)))
            } else {
                filename.clone()
            },
            size: document.file_length.unwrap_or(0),
            sha256: hex_of(&document.file_sha256),
            enc_sha256: hex_of(&document.file_enc_sha256),
            pages: document.page_count.unwrap_or(0),
            direct_path: text_of(&document.direct_path),
            media_key: hex_of(&document.media_key),
            media_key_ts: document.media_key_timestamp.unwrap_or(0),
            ..Media::default()
        });
        // The caption is what the sender wrote; the title is the document's own name when it has one.
        let caption = text_of(&document.caption);
        record.text = bounded(
            if caption.is_empty() { text_of(&document.title) } else { caption }.as_str(),
            MAX_TEXT,
        );
    } else if let Some(sticker) = base.sticker_message.as_option() {
        record.kind = "sticker".into();
        record.media = Some(Media {
            kind: "sticker".into(),
            mime: text_of(&sticker.mimetype),
            size: sticker.file_length.unwrap_or(0),
            sha256: hex_of(&sticker.file_sha256),
            enc_sha256: hex_of(&sticker.file_enc_sha256),
            width: sticker.width.unwrap_or(0),
            height: sticker.height.unwrap_or(0),
            direct_path: text_of(&sticker.direct_path),
            media_key: hex_of(&sticker.media_key),
            media_key_ts: sticker.media_key_timestamp.unwrap_or(0),
            animated: sticker.is_animated.unwrap_or(false),
            filename: format!("STK-{}.{}", short_id(&record.id), extension(&text_of(&sticker.mimetype))),
            ..Media::default()
        });
        // A sticker's own emoji tags are the only text it has: without them it is unfindable.
        record.text = bounded(&sticker.emojis.clone().unwrap_or_default(), MAX_TEXT);
    } else if let Some(location) = base.location_message.as_option() {
        record.kind = "location".into();
        record.place = Some(Place {
            lat: location.degrees_latitude.unwrap_or(0.0),
            lng: location.degrees_longitude.unwrap_or(0.0),
            name: bounded(&text_of(&location.name), 200),
            address: bounded(&text_of(&location.address), 300),
            live: location.is_live.unwrap_or(false),
        });
    } else if let Some(live) = base.live_location_message.as_option() {
        record.kind = "location".into();
        record.place = Some(Place {
            lat: live.degrees_latitude.unwrap_or(0.0),
            lng: live.degrees_longitude.unwrap_or(0.0),
            address: bounded(&text_of(&live.caption), 300),
            live: true,
            ..Place::default()
        });
    } else if let Some(contact) = base.contact_message.as_option() {
        record.kind = "contact".into();
        record.contacts = vec![contact_of(&text_of(&contact.display_name), &text_of(&contact.vcard))];
    } else if let Some(array) = base.contacts_array_message.as_option() {
        record.kind = "contact".into();
        record.contacts = array
            .contacts
            .iter()
            .take(MAX_CONTACTS)
            .map(|entry| contact_of(&text_of(&entry.display_name), &text_of(&entry.vcard)))
            .collect();
    } else if let Some(poll) = poll_of(base) {
        record.kind = "poll".into();
        record.poll = Some(poll);
    } else if record.kind.is_empty() {
        record.kind = "other".into();
        record.unsupported = "unsupported_kind".into();
    }

    // What must not be kept is not kept: view-once and ephemeral media arrive with keys we could use,
    // and the answer to "may this node read it later" is no.
    // `is_view_once` on the message as it arrived: `get_base_message` has already peeled the wrapper
    // that says so, and the inline flag on a modern payload is the same fact.
    let view_once = message.is_view_once() || base.is_view_once() || record.media.as_ref().is_some_and(|media| media.view_once);
    let ephemeral = message.is_ephemeral() || base.is_ephemeral();
    if view_once {
        record.unsupported = "view_once".into();
    } else if ephemeral {
        record.unsupported = "ephemeral_media_not_retained".into();
    }
    if !record.unsupported.is_empty() {
        record.text.clear();
        record.media = None;
        record.place = None;
        record.contacts.clear();
        record.poll = None;
        return record;
    }
    if let Some(media) = record.media.as_mut() {
        if media.size > MAX_MEDIA_BYTES {
            record.unsupported = "media_too_large".into();
        }
        media.downloadable = !media.direct_path.is_empty() && !media.media_key.is_empty();
    }
    record
}

fn poll_of(base: &wap::Message) -> Option<Poll> {
    let poll = base
        .poll_creation_message
        .as_option()
        .or_else(|| base.poll_creation_message_v2.as_option())
        .or_else(|| base.poll_creation_message_v3.as_option())?;
    Some(Poll {
        name: bounded(&text_of(&poll.name), 300),
        options: poll.options.iter().take(MAX_OPTIONS).map(|option| bounded(&text_of(&option.option_name), 120)).collect(),
        selectable: poll.selectable_options_count.unwrap_or(0),
    })
}

/// The text of an edit's replacement message: the body, or the caption of whatever it edits to.
fn edit_text(edited: &wap::Message) -> String {
    let base = edited.get_base_message();
    if let Some(text) = base.text_content() {
        return bounded(text, MAX_TEXT);
    }
    if let Some(caption) = base.get_caption() {
        return bounded(caption, MAX_TEXT);
    }
    String::new()
}

/// The context info of whichever body carries it (it is per-kind in the protobuf).
pub fn context_of(base: &wap::Message) -> Option<&wap::ContextInfo> {
    // Every body kind carries its own `context_info`; the first one present is the message's.
    if let Some(value) = base.extended_text_message.as_option() {
        return value.context_info.as_option();
    }
    if let Some(value) = base.image_message.as_option() {
        return value.context_info.as_option();
    }
    if let Some(value) = base.video_message.as_option() {
        return value.context_info.as_option();
    }
    if let Some(value) = base.audio_message.as_option() {
        return value.context_info.as_option();
    }
    if let Some(value) = base.document_message.as_option() {
        return value.context_info.as_option();
    }
    if let Some(value) = base.sticker_message.as_option() {
        return value.context_info.as_option();
    }
    if let Some(value) = base.location_message.as_option() {
        return value.context_info.as_option();
    }
    if let Some(value) = base.contact_message.as_option() {
        return value.context_info.as_option();
    }
    if let Some(value) = base.contacts_array_message.as_option() {
        return value.context_info.as_option();
    }
    if let Some(value) = base.poll_creation_message.as_option() {
        return value.context_info.as_option();
    }
    if let Some(value) = base.poll_creation_message_v2.as_option() {
        return value.context_info.as_option();
    }
    if let Some(value) = base.poll_creation_message_v3.as_option() {
        return value.context_info.as_option();
    }
    None
}

fn mentions_of(message: &wap::Message) -> Vec<String> {
    context_of(message.get_base_message())
        .map(|context| context.mentioned_jid.iter().filter(|jid| !jid.is_empty()).take(MAX_MENTIONS).cloned().collect())
        .unwrap_or_default()
}

/// A contact card reduced to what a query can answer with: the name and the phone numbers.
fn contact_of(display_name: &str, vcard: &str) -> Contact {
    let mut phones: Vec<String> = Vec::new();
    for line in vcard.lines().take(64) {
        let line = line.trim();
        // `TEL;type=CELL;waid=5511…:+55 11 …` - the number is after the last colon, the id often there.
        let (lower, value) = match line.split_once(':') {
            Some((head, value)) if head.to_ascii_uppercase().starts_with("TEL") => (head.to_ascii_lowercase(), value),
            _ => continue,
        };
        let digits: String = value.chars().filter(char::is_ascii_digit).collect();
        if digits.is_empty() || phones.len() >= 4 {
            continue;
        }
        let number = if lower.contains("waid=") {
            // The WhatsApp id is already a full number; prefer it to a formatted one.
            digits
        } else {
            digits
        };
        if !phones.contains(&number) {
            phones.push(number);
        }
    }
    let name = if display_name.is_empty() {
        vcard
            .lines()
            .find_map(|line| line.trim().strip_prefix("FN:").map(|value| value.trim().to_string()))
            .unwrap_or_default()
    } else {
        display_name.to_string()
    };
    Contact { name: bounded(&name, 200), phones }
}

/// Fold a string into what a token index compares: lowercase, accents stripped, everything that is not
/// a letter or a digit becomes a separator.
///
/// The Go connector searched with SQLite's `LIKE` on the raw body, so `ação` never matched `acao` and
/// a document named `Relatório.pdf` was unfindable as `relatorio`. Folding is what makes the index
/// worth having; it is done on the way in *and* on the way out, so a query typed either way matches.
pub fn fold(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for ch in text.chars() {
        let lower = ch.to_lowercase().next().unwrap_or(ch);
        let code = lower as u32;
        let folded = if (0xC0..=0xFF).contains(&code) {
            mapped(LATIN1, code - 0xC0, lower)
        } else if (0x100..=0x17F).contains(&code) {
            mapped(LATIN_EXT_A, code - 0x100, lower)
        } else {
            lower
        };
        // Letters and digits are the tokens; so is an emoji, because a sticker is found by the emoji
        // its sender tagged it with and "an emoji" has no letters to fold. Everything else separates.
        if folded.is_alphanumeric() || is_emoji(folded) {
            out.push(folded);
        } else {
            out.push(' ');
        }
    }
    out
}

/// The key a NAME is compared by: [`fold`], minus the emoji, with the spaces collapsed.
///
/// A name is not a search token. The operator saves a contact as `Laura ❤️` and then types `laura`;
/// folding keeps the emoji - a sticker is found by the emoji its sender tagged it with, so an emoji is
/// a token there - and a comparison that kept it would answer "Laura ❤️" as a *prefix* of "laura"
/// instead of the same name. Ignoring it is what the caller means by the name, and it is the one place
/// that decides so: `index::ChatCard::match_score` compares names through this and nothing else.
pub fn name_key(text: &str) -> String {
    fold(text).split_whitespace().filter(|token| !token.chars().any(is_emoji)).collect::<Vec<_>>().join(" ")
}

/// One entry of a folding table, or the character itself when the table has no opinion (`?`).
fn mapped(table: &str, index: u32, fallback: char) -> char {
    match table.chars().nth(index as usize) {
        Some('?') | None => fallback,
        Some(folded) => folded,
    }
}

/// A symbol that is not punctuation: what an emoji is, and what a token may be.
fn is_emoji(ch: char) -> bool {
    !ch.is_ascii() && !ch.is_whitespace() && !ch.is_alphanumeric() && !is_punctuation(ch)
}

/// Punctuation, which never belongs to a token (an emoji is a symbol, not punctuation).
fn is_punctuation(ch: char) -> bool {
    ch.is_ascii_punctuation()
        || ('\u{a1}'..='\u{bf}').contains(&ch)
        || ('\u{2010}'..='\u{2027}').contains(&ch)
        || ('\u{2030}'..='\u{205e}').contains(&ch)
        || ('\u{3000}'..='\u{303f}').contains(&ch)
}

/// The tokens of a text: folded, split, bounded, deduplicated in place by the caller.
pub fn tokenize(text: &str) -> Vec<String> {
    let mut tokens: Vec<String> = Vec::new();
    for token in fold(text).split_whitespace() {
        let chars = token.chars().count();
        if chars == 0 || chars > 40 {
            continue;
        }
        // A one-character token is dropped when it is a letter or a digit (nobody searches "a") and
        // kept when it is an emoji: a sticker is indexed by the emoji it was tagged with, and by
        // nothing else.
        if chars == 1 && token.chars().next().is_some_and(|ch| ch.is_alphanumeric()) {
            continue;
        }
        let token = token.to_string();
        if !tokens.iter().any(|seen| seen == &token) {
            tokens.push(token);
        }
    }
    tokens
}

/// Latin-1 supplement (U+00C0..U+00FF), one ASCII letter per character (`?` = no opinion).
pub const LATIN1: &str = "AAAAAAACEEEEIIIIDNOOOOO?OUUUUYTsaaaaaaaceeeeiiiidnooooo?ouuuuyty";

/// Latin Extended-A (U+0100..U+017F): the Polish, Czech, Baltic and Turkish letters a Portuguese or
/// English speaker still types without the accent.
pub const LATIN_EXT_A: &str = concat!(
    "AaAaAaCcCcCcCcDd",
    "DdEeEeEeEeGgGgGg",
    "GgGgGgHhHhIiIiIi",
    "IiIiJjKkkLlLlLlL",
    "lLlNnNnNnnNnOoOo",
    "OoOoRrRrRrSsSsSs",
    "SsTtTtTtUuUuUuUu",
    "UuUuWwYyYZzZzZzs",
);

/// One line, bounded: a snippet, a title or a reason never carries a newline into an answer.
pub fn one_line(text: &str, max: usize) -> String {
    let mut out: String = text
        .chars()
        .map(|ch| if ch.is_control() { ' ' } else { ch })
        .take(max)
        .collect();
    // Collapse the runs the mapping above and the source may have left behind.
    while out.contains("  ") {
        out = out.replace("  ", " ");
    }
    out.trim().to_string()
}

fn bounded(text: &str, max: usize) -> String {
    text.chars().take(max).collect()
}

fn text_of(field: &Option<String>) -> String {
    field.clone().unwrap_or_default()
}

fn hex_of(bytes: &Option<Vec<u8>>) -> String {
    match bytes {
        Some(bytes) => bytes.iter().map(|byte| format!("{byte:02x}")).collect(),
        None => String::new(),
    }
}

/// A short, stable, filename-safe piece of a message id (ids are opaque base64-ish strings).
fn short_id(id: &str) -> String {
    id.chars().filter(|ch| ch.is_ascii_alphanumeric()).take(12).collect()
}

/// The extension implied by a MIME type, for the name of a media file that arrived without one.
pub fn extension(mime: &str) -> &'static str {
    match mime.split(';').next().unwrap_or("").trim() {
        "image/jpeg" => "jpg",
        "image/png" => "png",
        "image/webp" => "webp",
        "image/gif" => "gif",
        "video/mp4" => "mp4",
        "video/3gpp" => "3gp",
        "audio/ogg" | "audio/ogg; codecs=opus" => "ogg",
        "audio/mpeg" => "mp3",
        "audio/mp4" => "m4a",
        "audio/wav" | "audio/x-wav" => "wav",
        "application/pdf" => "pdf",
        _ => "bin",
    }
}

/// The message kinds a media record can name, and whether the download path can fetch them.
pub fn media_kind(kind: &str) -> bool {
    matches!(kind, "image" | "video" | "audio" | "voice" | "document" | "sticker")
}

#[cfg(test)]
mod tests {
    use super::*;
    use whatsapp_rust::waproto::buffa::MessageField;

    fn envelope(id: &str) -> Envelope {
        Envelope { chat: "5511999999999@lid".into(), id: id.into(), sender: "5511888888888@s.whatsapp.net".into(), ts: 1_760_000_000_000, received: 1_760_000_000_100, ..Envelope::default() }
    }

    #[test]
    fn a_message_is_indexed_under_the_spelling_a_query_accepts() {
        // The chat an answer names is the chat a query can ask about (`chat::storable`, the one rule):
        // a legacy group id and a modern one are kept exactly, the phone server's legacy spelling is
        // normalized, and a shape the rule does not know is kept as it arrived instead of dropped.
        let text_message = wap::Message { conversation: Some("oi".into()), ..Default::default() };
        for (arrived, stored) in [
            ("9999999999999-9999999999999@g.us", "9999999999999-9999999999999@g.us"),
            ("120363000000000001@g.us", "120363000000000001@g.us"),
            ("5511999999999@c.us", "5511999999999@s.whatsapp.net"),
            ("5511999999999:12@s.whatsapp.net", "5511999999999:12@s.whatsapp.net"),
        ] {
            let env = Envelope { chat: arrived.into(), group: arrived.ends_with("@g.us"), ..envelope("S1") };
            let record = from_message(&env, &text_message);
            assert_eq!(record.chat, stored, "{arrived}");
        }
    }

    #[test]
    fn a_quote_and_its_mentions_are_part_of_the_record() {
        let message = wap::Message {
            extended_text_message: MessageField::some(wap::message::ExtendedTextMessage {
                text: Some("@5511977776666 confirma?".into()),
                context_info: MessageField::some(wap::ContextInfo {
                    stanza_id: Some("3EB0QUOTED".into()),
                    mentioned_jid: vec!["5511977776666@s.whatsapp.net".into(), String::new()],
                    ..Default::default()
                }),
                ..Default::default()
            }),
            ..Default::default()
        };
        let record = from_message(&envelope("M1"), &message);
        assert_eq!((record.kind.as_str(), record.text.as_str()), ("text", "@5511977776666 confirma?"));
        assert_eq!(record.quoted, "3EB0QUOTED", "a reply keeps the id it answers");
        assert_eq!(record.mentions, vec!["5511977776666@s.whatsapp.net".to_string()], "empty mentions are dropped");
    }

    #[test]
    fn a_contact_card_keeps_the_name_and_the_numbers_but_not_the_vcard() {
        let message = wap::Message {
            contact_message: MessageField::some(wap::message::ContactMessage {
                display_name: Some("Carlos".into()),
                vcard: Some(
                    "BEGIN:VCARD\nVERSION:3.0\nFN:Carlos Souza\nTEL;type=CELL;waid=5511977776666:+55 11 97777-6666\nTEL;type=HOME:+55 11 3333-4444\nEND:VCARD"
                        .into(),
                ),
                ..Default::default()
            }),
            ..Default::default()
        };
        let record = from_message(&envelope("C1"), &message);
        assert_eq!(record.kind, "contact");
        assert_eq!(record.contacts.len(), 1);
        assert_eq!(record.contacts[0].name, "Carlos");
        assert_eq!(record.contacts[0].phones, vec!["5511977776666".to_string(), "551133334444".to_string()]);
        assert_eq!(record.body(), "Carlos", "the card's name is what a search answers with");
        let searchable = record.searchable();
        assert!(!searchable.contains("BEGIN:VCARD"), "the vcard body is not kept");
    }

    #[test]
    fn a_contact_card_without_a_display_name_takes_the_vcards_own() {
        let message = wap::Message {
            contact_message: MessageField::some(wap::message::ContactMessage {
                display_name: None,
                vcard: Some("BEGIN:VCARD\nFN:Ana Paula\nTEL;type=CELL:5511911112222\nEND:VCARD".into()),
                ..Default::default()
            }),
            ..Default::default()
        };
        assert_eq!(from_message(&envelope("C1"), &message).contacts[0].name, "Ana Paula");
    }

    #[test]
    fn a_poll_keeps_its_question_and_options() {
        let message = wap::Message {
            poll_creation_message_v3: MessageField::some(wap::message::PollCreationMessage {
                name: Some("onde jantar?".into()),
                options: vec![
                    wap::message::poll_creation_message::Option { option_name: Some("pizza".into()), ..Default::default() },
                    wap::message::poll_creation_message::Option { option_name: Some("sushi".into()), ..Default::default() },
                ],
                selectable_options_count: Some(1),
                ..Default::default()
            }),
            ..Default::default()
        };
        let record = from_message(&envelope("P1"), &message);
        let poll = record.poll.clone().unwrap();
        assert_eq!((poll.name.as_str(), poll.options.len(), poll.selectable), ("onde jantar?", 2, 1));
        assert!(record.searchable().contains("sushi"), "a poll is found by its options too");
    }

    #[test]
    fn a_location_keeps_the_coordinates_as_well_as_the_labels() {
        let message = wap::Message {
            location_message: MessageField::some(wap::message::LocationMessage {
                degrees_latitude: Some(-23.5),
                degrees_longitude: Some(-46.6),
                name: Some("Padaria".into()),
                ..Default::default()
            }),
            ..Default::default()
        };
        let place = from_message(&envelope("L1"), &message).place.unwrap();
        assert_eq!((place.lat, place.lng), (-23.5, -46.6));
        assert!(!place.live);
    }

    #[test]
    fn an_unsupported_body_is_a_fact_and_not_a_silent_drop() {
        let message = wap::Message {
            call: MessageField::some(wap::message::Call { ..Default::default() }),
            ..Default::default()
        };
        let record = from_message(&envelope("X1"), &message);
        assert_eq!(record.kind, "other");
        assert_eq!(record.unsupported, "unsupported_kind");
    }

    #[test]
    fn ephemeral_media_is_a_fact_with_no_text_and_no_keys() {
        let inner = wap::Message {
            image_message: MessageField::some(wap::message::ImageMessage {
                caption: Some("some com o timer".into()),
                media_key: Some(vec![1; 32]),
                direct_path: Some("/v/x".into()),
                ..Default::default()
            }),
            ..Default::default()
        };
        let message = wap::Message {
            ephemeral_message: MessageField::some(wap::message::FutureProofMessage { message: MessageField::some(inner), ..Default::default() }),
            ..Default::default()
        };
        let record = from_message(&envelope("I1"), &message);
        assert_eq!(record.unsupported, "ephemeral_media_not_retained");
        assert!(record.text.is_empty() && record.media.is_none());
    }

    #[test]
    fn oversized_media_is_recorded_as_metadata_only() {
        let message = wap::Message {
            video_message: MessageField::some(wap::message::VideoMessage {
                mimetype: Some("video/mp4".into()),
                file_length: Some(MAX_MEDIA_BYTES + 1),
                direct_path: Some("/v/big".into()),
                media_key: Some(vec![2; 32]),
                ..Default::default()
            }),
            ..Default::default()
        };
        let record = from_message(&envelope("V1"), &message);
        assert_eq!(record.unsupported, "media_too_large");
        let media = record.media.unwrap();
        assert!(media.downloadable, "the metadata still says how to fetch it");
        assert_eq!(media.mime, "video/mp4");
    }

    #[test]
    fn a_media_record_is_downloadable_only_with_both_the_path_and_the_key() {
        let mut message = wap::Message {
            image_message: MessageField::some(wap::message::ImageMessage {
                mimetype: Some("image/jpeg".into()),
                direct_path: Some("/v/x".into()),
                ..Default::default()
            }),
            ..Default::default()
        };
        assert!(!from_message(&envelope("I1"), &message).media.unwrap().downloadable, "no media key");
        message.image_message = MessageField::some(wap::message::ImageMessage {
            mimetype: Some("image/jpeg".into()),
            direct_path: Some("/v/x".into()),
            media_key: Some(vec![3; 32]),
            ..Default::default()
        });
        assert!(from_message(&envelope("I1"), &message).media.unwrap().downloadable);
    }

    #[test]
    fn an_unsupported_protocol_message_is_named_after_its_type() {
        let message = wap::Message {
            protocol_message: MessageField::some(wap::message::ProtocolMessage {
                r#type: Some(wap::message::protocol_message::Type::EPHEMERAL_SETTING),
                ..Default::default()
            }),
            ..Default::default()
        };
        let record = from_message(&envelope("X1"), &message);
        assert_eq!(record.kind, "other");
        assert!(record.unsupported.starts_with("protocol_"), "{}", record.unsupported);
    }

    #[test]
    fn an_extension_is_derived_from_the_mime_type() {
        assert_eq!(extension("image/jpeg"), "jpg");
        assert_eq!(extension("audio/ogg; codecs=opus"), "ogg");
        assert_eq!(extension("application/pdf"), "pdf");
        assert_eq!(extension("application/x-weird"), "bin");
    }

    #[test]
    fn a_snippet_is_one_bounded_line() {
        assert_eq!(one_line("linha um\nlinha dois", 40), "linha um linha dois");
        let long = "x".repeat(400);
        assert_eq!(one_line(&long, 280).chars().count(), 280);
    }

    #[test]
    fn tokens_are_folded_deduplicated_and_bounded() {
        assert_eq!(tokenize("Acao acao ACAO"), vec!["acao".to_string()]);
        assert_eq!(tokenize("uma a de o"), vec!["uma".to_string(), "de".to_string()], "a one-letter word is not a token");
        assert_eq!(tokenize("\u{1f602}"), vec!["\u{1f602}".to_string()], "an emoji is a token");
        assert!(tokenize(&"palavra ".repeat(200)).len() <= 200);
    }
}
