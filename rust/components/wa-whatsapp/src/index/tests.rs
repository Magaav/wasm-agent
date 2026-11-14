//! The index against a fake client: hand-built protocol messages in, `whatsapp_search`/`read`/
//! `reactions`/`media` answers out.
//!
//! No test here touches WhatsApp, a socket or the host: the "client" is a `wa::Message` built by hand
//! (exactly the shape the protocol crate hands `on_message`) and the "host" is [`Memory`], which is the
//! same `kv` contract without a store. That is what lets every message kind, the mutation events and
//! the retention window be measured in `cargo test`, on a machine that never paired.
use super::*;
use crate::chat;
use crate::history;
use crate::record::{self, Envelope, Record};
use futures::executor::block_on;
use wa_whatsapp_index as seam;
use whatsapp_rust::waproto::buffa::MessageField;
use whatsapp_rust::waproto::whatsapp as wap;

const CHAT: &str = "120363000000000001@g.us";
const LID: &str = "72103978127547@lid";
const SENDER: &str = "5511999999999@s.whatsapp.net";
const OTHER: &str = "5511888888888@s.whatsapp.net";

fn envelope(id: &str, ts: i64) -> Envelope {
    Envelope {
        chat: CHAT.into(),
        id: id.into(),
        sender: SENDER.into(),
        sender_alt: String::new(),
        own: false,
        group: true,
        ts,
        received: ts + 5,
        push_name: "Ana".into(),
        business: String::new(),
    }
}

fn text(id: &str, ts: i64, body: &str) -> Record {
    let message = wap::Message { conversation: Some(body.to_string()), ..Default::default() };
    record::from_message(&envelope(id, ts), &message)
}

fn image(id: &str, ts: i64, caption: &str) -> Record {
    let message = wap::Message {
        image_message: MessageField::some(wap::message::ImageMessage {
            mimetype: Some("image/jpeg".into()),
            caption: Some(caption.into()),
            file_length: Some(48_213),
            file_sha256: Some(vec![0xab; 32]),
            file_enc_sha256: Some(vec![0xcd; 32]),
            media_key: Some(vec![0x11; 32]),
            direct_path: Some("/v/t62.7118-24/abc".into()),
            width: Some(1080),
            height: Some(1920),
            ..Default::default()
        }),
        ..Default::default()
    };
    record::from_message(&envelope(id, ts), &message)
}

fn verified(request: seam::Request) -> seam::Verified {
    request.validate().expect("a valid test request")
}

fn search_request(q: &str) -> seam::Verified {
    verified(seam::Request { op: "search".into(), q: Some(q.into()), ..Default::default() })
}

fn read_request(limit: u32) -> seam::Verified {
    verified(seam::Request { op: "read".into(), chat: Some(CHAT.into()), limit: Some(limit), ..Default::default() })
}

// ---- every kind ----------------------------------------------------------------------------------

#[test]
fn every_message_kind_is_indexed_and_answerable() {
    let store = Memory::new();
    let base = 1_760_000_000_000;
    let kinds: Vec<(&str, Record)> = vec![
        ("text", text("T1", base, "segue o boleto")),
        ("image", image("I1", base + 1, "foto do recibo")),
        (
            "video",
            record::from_message(
                &envelope("V1", base + 2),
                &wap::Message {
                    video_message: MessageField::some(wap::message::VideoMessage {
                        mimetype: Some("video/mp4".into()),
                        file_length: Some(3_000_000),
                        seconds: Some(42),
                        caption: Some("passeio".into()),
                        media_key: Some(vec![2; 32]),
                        direct_path: Some("/v/video".into()),
                        ..Default::default()
                    }),
                    ..Default::default()
                },
            ),
        ),
        (
            "voice",
            record::from_message(
                &envelope("A1", base + 3),
                &wap::Message {
                    audio_message: MessageField::some(wap::message::AudioMessage {
                        mimetype: Some("audio/ogg; codecs=opus".into()),
                        ptt: Some(true),
                        seconds: Some(11),
                        file_length: Some(9_000),
                        media_key: Some(vec![3; 32]),
                        direct_path: Some("/v/ptt".into()),
                        ..Default::default()
                    }),
                    ..Default::default()
                },
            ),
        ),
        (
            "audio",
            record::from_message(
                &envelope("A2", base + 4),
                &wap::Message {
                    audio_message: MessageField::some(wap::message::AudioMessage {
                        mimetype: Some("audio/mpeg".into()),
                        ptt: Some(false),
                        seconds: Some(240),
                        ..Default::default()
                    }),
                    ..Default::default()
                },
            ),
        ),
        (
            "document",
            record::from_message(
                &envelope("D1", base + 5),
                &wap::Message {
                    document_message: MessageField::some(wap::message::DocumentMessage {
                        mimetype: Some("application/pdf".into()),
                        file_name: Some("Relatório-2026.pdf".into()),
                        caption: Some("o relatório do mês".into()),
                        file_length: Some(120_000),
                        page_count: Some(7),
                        file_sha256: Some(vec![9; 32]),
                        media_key: Some(vec![4; 32]),
                        direct_path: Some("/v/doc".into()),
                        ..Default::default()
                    }),
                    ..Default::default()
                },
            ),
        ),
        (
            "sticker",
            record::from_message(
                &envelope("S1", base + 6),
                &wap::Message {
                    sticker_message: MessageField::some(wap::message::StickerMessage {
                        mimetype: Some("image/webp".into()),
                        is_animated: Some(true),
                        emojis: Some("😂".into()),
                        file_length: Some(2_000),
                        ..Default::default()
                    }),
                    ..Default::default()
                },
            ),
        ),
        (
            "location",
            record::from_message(
                &envelope("L1", base + 7),
                &wap::Message {
                    location_message: MessageField::some(wap::message::LocationMessage {
                        degrees_latitude: Some(-23.5613),
                        degrees_longitude: Some(-46.6565),
                        name: Some("Padaria do Zé".into()),
                        address: Some("Rua Augusta, 1000".into()),
                        ..Default::default()
                    }),
                    ..Default::default()
                },
            ),
        ),
        (
            "contact",
            record::from_message(
                &envelope("C1", base + 8),
                &wap::Message {
                    contact_message: MessageField::some(wap::message::ContactMessage {
                        display_name: Some("Carlos Souza".into()),
                        vcard: Some("BEGIN:VCARD\nFN:Carlos Souza\nTEL;type=CELL;waid=5511977776666:+55 11 97777-6666\nEND:VCARD".into()),
                        ..Default::default()
                    }),
                    ..Default::default()
                },
            ),
        ),
        (
            "poll",
            record::from_message(
                &envelope("P1", base + 9),
                &wap::Message {
                    poll_creation_message: MessageField::some(wap::message::PollCreationMessage {
                        name: Some("onde jantar?".into()),
                        options: vec![
                            wap::message::poll_creation_message::Option { option_name: Some("pizza".into()), ..Default::default() },
                            wap::message::poll_creation_message::Option { option_name: Some("sushi".into()), ..Default::default() },
                        ],
                        selectable_options_count: Some(1),
                        ..Default::default()
                    }),
                    ..Default::default()
                },
            ),
        ),
    ];
    for (kind, record) in &kinds {
        assert_eq!(&record.kind, kind, "{kind}: classified");
        block_on(put(&store, record)).unwrap();
    }

    // One thread read lists them newest first, each with the kind the brief names.
    let answer = block_on(read(&store, &read_request(20))).unwrap();
    let messages = answer["messages"].as_array().unwrap();
    assert_eq!(messages.len(), kinds.len(), "every kind is in the thread");
    let found: Vec<String> = messages.iter().map(|m| m["kind"].as_str().unwrap().to_string()).collect();
    for (kind, _) in &kinds {
        assert!(found.contains(&kind.to_string()), "{kind} is missing from the thread: {found:?}");
    }
    // Newest first, by the message's own timestamp.
    let stamps: Vec<i64> = messages.iter().map(|m| m["ts"].as_i64().unwrap()).collect();
    let mut sorted = stamps.clone();
    sorted.sort_by(|a, b| b.cmp(a));
    assert_eq!(stamps, sorted);

    // Each kind is findable by what makes it itself: a caption, a filename, a sticker's emoji, a place,
    // a contact's name, a poll's question.
    for (q, kind) in [
        ("recibo", "image"),
        ("passeio", "video"),
        ("relatorio", "document"),
        ("😂", "sticker"),
        ("padaria", "location"),
        ("carlos", "contact"),
        ("jantar", "poll"),
    ] {
        let answer = block_on(search(&store, &search_request(q))).unwrap();
        let hits = answer["hits"].as_array().unwrap();
        assert!(!hits.is_empty(), "{q:?} found nothing");
        assert!(
            hits.iter().any(|hit| hit["kind"] == kind),
            "{q:?} did not find the {kind}: {hits:?}"
        );
    }
}

#[test]
fn a_documents_metadata_answers_the_briefs_fields() {
    let store = Memory::new();
    let record = record::from_message(
        &envelope("D1", 1_760_000_000_000),
        &wap::Message {
            document_message: MessageField::some(wap::message::DocumentMessage {
                mimetype: Some("application/pdf".into()),
                file_name: Some("contrato.pdf".into()),
                caption: Some("assine hoje".into()),
                file_length: Some(88_000),
                page_count: Some(3),
                file_sha256: Some(vec![0x5a; 32]),
                media_key: Some(vec![7; 32]),
                direct_path: Some("/v/doc".into()),
                ..Default::default()
            }),
            ..Default::default()
        },
    );
    block_on(put(&store, &record)).unwrap();
    let request = verified(seam::Request {
        op: "media".into(),
        chat: Some(CHAT.into()),
        id: Some("D1".into()),
        ..Default::default()
    });
    let answer = block_on(media(&store, &request)).unwrap();
    assert_eq!(answer["media"]["mime"], "application/pdf");
    assert_eq!(answer["media"]["filename"], "contrato.pdf");
    assert_eq!(answer["media"]["size"], 88_000);
    assert_eq!(answer["media"]["pages"], 3);
    assert_eq!(answer["media"]["sha256"].as_str().unwrap().len(), 64);
    assert_eq!(answer["downloadable"], true);
    assert_eq!(answer["text"], "assine hoje");
    // The media key and the direct path are how the component decrypts: they never appear in an answer.
    let text = answer.to_string();
    assert!(!text.contains("07070707"), "the media key must not be in an answer");
    assert!(!text.contains("/v/doc"), "the direct path must not be in an answer");
}

#[test]
fn a_voice_note_is_found_by_its_transcript_and_keeps_its_duration() {
    let store = Memory::new();
    let voice = record::from_message(
        &envelope("A1", 1_760_000_000_000),
        &wap::Message {
            audio_message: MessageField::some(wap::message::AudioMessage {
                mimetype: Some("audio/ogg; codecs=opus".into()),
                ptt: Some(true),
                seconds: Some(37),
                file_length: Some(40_000),
                media_key: Some(vec![1; 32]),
                direct_path: Some("/v/ptt".into()),
                ..Default::default()
            }),
            ..Default::default()
        },
    );
    block_on(put(&store, &voice)).unwrap();
    // The transcription pipeline attaches what was said; the index makes it searchable.
    assert!(block_on(attach_text(&store, CHAT, "A1", "a reunião de amanhã está confirmada", Source::Transcript)).unwrap());
    let answer = block_on(search(&store, &search_request("reuniao"))).unwrap();
    let hits = answer["hits"].as_array().unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0]["kind"], "voice");
    assert!(hits[0]["transcript"].as_str().unwrap().contains("reunião"));
    // And an OCR pass on a photo is searchable the same way.
    block_on(put(&store, &image("I1", 1_760_000_001_000, "recibo"))).unwrap();
    assert!(block_on(attach_text(&store, CHAT, "I1", "SUPERMERCADO CENTRAL 12,90", Source::Ocr)).unwrap());
    let answer = block_on(search(&store, &search_request("supermercado"))).unwrap();
    assert_eq!(answer["hits"].as_array().unwrap().len(), 1);
    let answer = block_on(media(&store, &verified(seam::Request {
        op: "media".into(),
        chat: Some(CHAT.into()),
        id: Some("A1".into()),
        ..Default::default()
    })))
    .unwrap();
    assert_eq!(answer["media"]["duration_s"], 37);
    assert_eq!(answer["media"]["kind"], "voice");
}

#[test]
fn the_token_index_folds_accents_on_both_sides() {
    let store = Memory::new();
    block_on(put(&store, &text("T1", 1_760_000_000_000, "Ação de cobrança do relatório"))).unwrap();
    for q in ["acao", "ação", "ACÃO", "cobranca", "relatorio"] {
        let answer = block_on(search(&store, &search_request(q))).unwrap();
        assert_eq!(answer["hits"].as_array().unwrap().len(), 1, "{q:?} should find it");
    }
    // A word it does not contain finds nothing: the index is not a prefix fuzzer.
    let answer = block_on(search(&store, &search_request("cobranças"))).unwrap();
    assert_eq!(answer["hits"].as_array().unwrap().len(), 0);
    assert_eq!(record::fold("Ação"), "acao");
    assert_eq!(record::fold("Łódź"), "lodz");
    assert_eq!(record::LATIN1.chars().count(), 64, "the Latin-1 table is one entry per character");
    assert_eq!(record::LATIN_EXT_A.chars().count(), 128, "the Latin Extended-A table is one entry per character");
}

// ---- events --------------------------------------------------------------------------------------

#[test]
fn reactions_add_change_and_remove_and_are_folded_onto_their_target() {
    let store = Memory::new();
    let ts = 1_760_000_000_000;
    block_on(put(&store, &text("T1", ts, "bom dia"))).unwrap();

    let reactions_request = verified(seam::Request {
        op: "reactions".into(),
        chat: Some(CHAT.into()),
        id: Some("T1".into()),
        ..Default::default()
    });

    // Two people react.
    for (id, sender, emoji) in [("R1", SENDER, "👍"), ("R2", OTHER, "❤️")] {
        let mut reaction = record::from_message(
            &Envelope { sender: sender.into(), ..envelope(id, ts + 10) },
            &wap::Message {
                reaction_message: MessageField::some(wap::message::ReactionMessage {
                    key: MessageField::some(wap::MessageKey { id: Some("T1".into()), ..Default::default() }),
                    text: Some(emoji.into()),
                    ..Default::default()
                }),
                ..Default::default()
            },
        );
        reaction.target = "T1".into();
        block_on(put(&store, &reaction)).unwrap();
    }
    let answer = block_on(reactions(&store, &reactions_request)).unwrap();
    assert_eq!(answer["count"], 2);
    assert_eq!(answer["by_emoji"]["👍"], 1);
    assert_eq!(answer["by_emoji"]["❤️"], 1);

    // The same actor changing the emoji replaces her own reaction, it does not add a second.
    let mut changed = record::from_message(
        &envelope("R3", ts + 20),
        &wap::Message {
            reaction_message: MessageField::some(wap::message::ReactionMessage {
                key: MessageField::some(wap::MessageKey { id: Some("T1".into()), ..Default::default() }),
                text: Some("😂".into()),
                ..Default::default()
            }),
            ..Default::default()
        },
    );
    changed.target = "T1".into();
    block_on(put(&store, &changed)).unwrap();
    let answer = block_on(reactions(&store, &reactions_request)).unwrap();
    assert_eq!(answer["count"], 2, "one reaction per actor: {answer}");
    let emojis: Vec<&str> = answer["reactions"].as_array().unwrap().iter().map(|row| row["emoji"].as_str().unwrap()).collect();
    assert!(emojis.contains(&"😂") && emojis.contains(&"❤️") && !emojis.contains(&"👍"), "{emojis:?}");

    // Taking it back is the same message with an empty text.
    let mut removed = record::from_message(
        &envelope("R4", ts + 30),
        &wap::Message {
            reaction_message: MessageField::some(wap::message::ReactionMessage {
                key: MessageField::some(wap::MessageKey { id: Some("T1".into()), ..Default::default() }),
                text: Some(String::new()),
                ..Default::default()
            }),
            ..Default::default()
        },
    );
    removed.target = "T1".into();
    block_on(put(&store, &removed)).unwrap();
    let answer = block_on(reactions(&store, &reactions_request)).unwrap();
    assert_eq!(answer["count"], 1, "one actor took hers back: {answer}");
    assert_eq!(answer["reactions"][0]["emoji"], "❤️");

    // A thread read folds what is left onto the message it answers, and does not show reaction bubbles.
    let answer = block_on(read(&store, &read_request(20))).unwrap();
    let messages = answer["messages"].as_array().unwrap();
    let bubbles: Vec<&str> = messages.iter().map(|m| m["kind"].as_str().unwrap()).collect();
    assert_eq!(bubbles.iter().filter(|kind| **kind == "T1" || **kind == "text").count(), 1, "{bubbles:?}");
    let target = messages.iter().find(|m| m["id"] == "T1").unwrap();
    assert_eq!(target["reactions"].as_array().unwrap().len(), 1);
    assert_eq!(target["reactions"][0]["emoji"], "❤️");
}

#[test]
fn an_edit_replaces_the_text_indexes_the_new_words_and_is_itself_an_event() {
    let store = Memory::new();
    let ts = 1_760_000_000_000;
    block_on(put(&store, &text("T1", ts, "chego as nove"))).unwrap();
    let edit = record::from_message(
        &envelope("E1", ts + 60),
        &wap::Message {
            protocol_message: MessageField::some(wap::message::ProtocolMessage {
                r#type: Some(wap::message::protocol_message::Type::MESSAGE_EDIT),
                key: MessageField::some(wap::MessageKey { id: Some("T1".into()), ..Default::default() }),
                edited_message: MessageField::some(wap::Message {
                    conversation: Some("chego as dez".into()),
                    ..Default::default()
                }),
                ..Default::default()
            }),
            ..Default::default()
        },
    );
    assert_eq!(edit.kind, "edit");
    assert_eq!(edit.target, "T1");
    block_on(put(&store, &edit)).unwrap();

    let target = block_on(load(&store, CHAT, "T1")).unwrap().unwrap();
    assert_eq!(target.text, "chego as dez");
    assert!(target.edited);
    assert_eq!(target.edits, 1);
    // "nove" is gone from the index; "dez" is in it.
    assert_eq!(block_on(search(&store, &search_request("nove"))).unwrap()["hits"].as_array().unwrap().len(), 0);
    assert_eq!(block_on(search(&store, &search_request("dez"))).unwrap()["hits"].as_array().unwrap().len(), 2, "the message and the edit event");
    // The event is in the thread, with the target it changed.
    let answer = block_on(read(&store, &read_request(20))).unwrap();
    let messages = answer["messages"].as_array().unwrap();
    assert_eq!(messages[0]["kind"], "edit");
    assert_eq!(messages[0]["target"], "T1");
    assert_eq!(messages[0]["text"], "chego as dez");
}

#[test]
fn a_delete_removes_the_text_the_media_and_every_token() {
    let store = Memory::new();
    let ts = 1_760_000_000_000;
    block_on(put(&store, &image("I1", ts, "o comprovante do pix"))).unwrap();
    assert_eq!(block_on(search(&store, &search_request("comprovante"))).unwrap()["hits"].as_array().unwrap().len(), 1);

    let delete = record::from_message(
        &envelope("E2", ts + 30),
        &wap::Message {
            protocol_message: MessageField::some(wap::message::ProtocolMessage {
                r#type: Some(wap::message::protocol_message::Type::REVOKE),
                key: MessageField::some(wap::MessageKey { id: Some("I1".into()), ..Default::default() }),
                ..Default::default()
            }),
            ..Default::default()
        },
    );
    assert_eq!(delete.kind, "delete");
    block_on(put(&store, &delete)).unwrap();

    let target = block_on(load(&store, CHAT, "I1")).unwrap().unwrap();
    assert!(target.deleted);
    assert!(target.text.is_empty() && target.media.is_none());
    // The words the sender took back are not findable, and neither is the media key.
    assert_eq!(block_on(search(&store, &search_request("comprovante"))).unwrap()["hits"].as_array().unwrap().len(), 0);
    let leftover: Vec<String> = store.keys().into_iter().filter(|key| key.contains("comprovante")).collect();
    assert!(leftover.is_empty(), "token keys left behind: {leftover:?}");
    // The fact is still there: a thread read shows the message, marked deleted.
    let answer = block_on(read(&store, &read_request(20))).unwrap();
    let message = answer["messages"].as_array().unwrap().iter().find(|m| m["id"] == "I1").cloned().unwrap();
    assert_eq!(message["deleted"], true);
    assert_eq!(message["text"], "");
}

#[test]
fn a_revoke_that_arrives_before_its_message_still_wins() {
    let store = Memory::new();
    let ts = 1_760_000_000_000;
    let delete = record::from_message(
        &envelope("E2", ts + 30),
        &wap::Message {
            protocol_message: MessageField::some(wap::message::ProtocolMessage {
                r#type: Some(wap::message::protocol_message::Type::REVOKE),
                key: MessageField::some(wap::MessageKey { id: Some("I1".into()), ..Default::default() }),
                ..Default::default()
            }),
            ..Default::default()
        },
    );
    block_on(put(&store, &delete)).unwrap();
    // Now the message itself lands (a re-delivery, a history sync).
    block_on(put(&store, &image("I1", ts, "o comprovante do pix"))).unwrap();
    let target = block_on(load(&store, CHAT, "I1")).unwrap().unwrap();
    assert!(target.deleted, "the tombstone is applied when the record lands");
    assert!(target.text.is_empty());
    assert_eq!(block_on(search(&store, &search_request("comprovante"))).unwrap()["hits"].as_array().unwrap().len(), 0);
}

#[test]
fn a_view_once_message_is_a_fact_without_text_or_keys() {
    let store = Memory::new();
    let message = wap::Message {
        view_once_message_v2: MessageField::some(wap::message::FutureProofMessage {
            message: MessageField::some(wap::Message {
                image_message: MessageField::some(wap::message::ImageMessage {
                    mimetype: Some("image/jpeg".into()),
                    caption: Some("só uma vez".into()),
                    media_key: Some(vec![9; 32]),
                    direct_path: Some("/v/x".into()),
                    ..Default::default()
                }),
                ..Default::default()
            }),
            ..Default::default()
        }),
        ..Default::default()
    };
    let record = record::from_message(&envelope("I1", 1_760_000_000_000), &message);
    assert_eq!(record.unsupported, "view_once");
    assert!(record.text.is_empty() && record.media.is_none());
    block_on(put(&store, &record)).unwrap();
    let answer = block_on(read(&store, &read_request(10))).unwrap();
    assert_eq!(answer["messages"][0]["unsupported"], "view_once");
    assert_eq!(block_on(search(&store, &search_request("vez"))).unwrap()["hits"].as_array().unwrap().len(), 0);
}

// ---- ranking, filters and limits ------------------------------------------------------------------

#[test]
fn search_ranks_an_exact_phrase_over_scattered_words_and_newer_over_older() {
    let store = Memory::new();
    let ts = 1_760_000_000_000;
    let records = [
        // Same tokens, scattered: "boleto" and "vencimento" in different places.
        text("T1", ts, "vencimento do contrato; boleto anexo"),
        // The exact phrase.
        text("T2", ts + 10, "o boleto vencimento sai amanhã"),
        // A file whose name carries both.
        record::from_message(
            &envelope("D1", ts + 20),
            &wap::Message {
                document_message: MessageField::some(wap::message::DocumentMessage {
                    mimetype: Some("application/pdf".into()),
                    file_name: Some("boleto-vencimento.pdf".into()),
                    ..Default::default()
                }),
                ..Default::default()
            },
        ),
    ];
    for record in &records {
        block_on(put(&store, record)).unwrap();
    }
    let answer = block_on(search(&store, &search_request("boleto vencimento"))).unwrap();
    let hits = answer["hits"].as_array().unwrap();
    assert_eq!(hits.len(), 3);
    // The phrase wins; the filename gets its bonus; the scattered one is last.
    assert_eq!(hits[0]["id"], "T2", "{hits:#?}");
    assert_eq!(hits[2]["id"], "T1", "{hits:#?}");
    let scores: Vec<i64> = hits.iter().map(|hit| hit["score"].as_i64().unwrap()).collect();
    assert!(scores[0] >= scores[1] && scores[1] >= scores[2], "{scores:?}");
    // Between two equally good hits the newer one is first.
    let store2 = Memory::new();
    for (id, offset) in [("OLD", 0), ("NEW", 1_000)] {
        block_on(put(&store2, &text(id, ts + offset, "mesma palavra"))).unwrap();
    }
    let answer = block_on(search(&store2, &search_request("palavra"))).unwrap();
    assert_eq!(answer["hits"][0]["id"], "NEW");
}

#[test]
fn search_filters_by_chat_kind_sender_and_window() {
    let store = Memory::new();
    let ts = 1_760_000_000_000;
    block_on(put(&store, &text("T1", ts, "contrato assinado"))).unwrap();
    let mut other_chat = text("T2", ts + 1, "contrato assinado");
    other_chat.chat = LID.into();
    block_on(put(&store, &other_chat)).unwrap();
    let mut from_other = text("T3", ts + 2, "contrato assinado");
    from_other.sender = OTHER.into();
    block_on(put(&store, &from_other)).unwrap();
    block_on(put(&store, &image("I1", ts + 3, "contrato assinado"))).unwrap();

    let all = block_on(search(&store, &search_request("contrato"))).unwrap();
    assert_eq!(all["hits"].as_array().unwrap().len(), 4);

    let only_chat = verified(seam::Request {
        op: "search".into(),
        q: Some("contrato".into()),
        chat: Some(CHAT.into()),
        ..Default::default()
    });
    assert_eq!(block_on(search(&store, &only_chat)).unwrap()["hits"].as_array().unwrap().len(), 3);

    let only_kind = verified(seam::Request {
        op: "search".into(),
        q: Some("contrato".into()),
        kind: Some("image".into()),
        ..Default::default()
    });
    let answer = block_on(search(&store, &only_kind)).unwrap();
    assert_eq!(answer["hits"].as_array().unwrap().len(), 1);
    assert_eq!(answer["hits"][0]["id"], "I1");

    let only_sender = verified(seam::Request {
        op: "search".into(),
        q: Some("contrato".into()),
        from: Some(OTHER.into()),
        ..Default::default()
    });
    let answer = block_on(search(&store, &only_sender)).unwrap();
    assert_eq!(answer["hits"].as_array().unwrap().len(), 1);
    assert_eq!(answer["hits"][0]["id"], "T3");

    let window = verified(seam::Request {
        op: "search".into(),
        q: Some("contrato".into()),
        since: Some(ts + 2),
        until: Some(ts + 3),
        ..Default::default()
    });
    let answer = block_on(search(&store, &window)).unwrap();
    let ids: Vec<&str> = answer["hits"].as_array().unwrap().iter().map(|hit| hit["id"].as_str().unwrap()).collect();
    assert_eq!(ids.len(), 2, "{ids:?}");
    assert!(ids.contains(&"T3") && ids.contains(&"I1"), "{ids:?}");

    // A search with no free text but a kind is a listing, not an error.
    let by_kind = verified(seam::Request { op: "search".into(), kind: Some("text".into()), ..Default::default() });
    assert_eq!(block_on(search(&store, &by_kind)).unwrap()["hits"].as_array().unwrap().len(), 3);
}

#[test]
fn limits_page_a_thread_and_cap_a_search() {
    let store = Memory::new();
    let ts = 1_760_000_000_000;
    for i in 0..30 {
        block_on(put(&store, &text(&format!("T{i:02}"), ts + i, "mensagem"))).unwrap();
    }
    let first = block_on(read(&store, &read_request(10))).unwrap();
    assert_eq!(first["count"], 10);
    assert_eq!(first["has_more"], true);
    assert_eq!(first["messages"][0]["id"], "T29", "newest first");
    let next_before = first["next_before"].as_str().unwrap().to_string();
    // The next page continues exactly where the first stopped, with no overlap.
    let second = block_on(read(
        &store,
        &verified(seam::Request {
            op: "read".into(),
            chat: Some(CHAT.into()),
            limit: Some(10),
            before: Some(next_before),
            ..Default::default()
        }),
    ))
    .unwrap();
    assert_eq!(second["messages"][0]["id"], "T19");
    assert_eq!(second["count"], 10);

    let search = block_on(search(
        &store,
        &verified(seam::Request { op: "search".into(), q: Some("mensagem".into()), limit: Some(5), ..Default::default() }),
    ))
    .unwrap();
    assert_eq!(search["hits"].as_array().unwrap().len(), 5);
    assert_eq!(search["truncated"], true);
    assert_eq!(search["matched"], 30, "the answer says how many matched, not only how many it kept");
}

#[test]
fn an_unknown_id_answers_nothing_rather_than_everything() {
    let store = Memory::new();
    block_on(put(&store, &text("T1", 1_760_000_000_000, "oi"))).unwrap();
    let answer = block_on(read(
        &store,
        &verified(seam::Request {
            op: "read".into(),
            chat: Some(CHAT.into()),
            before: Some("NEVER-SEEN".into()),
            ..Default::default()
        }),
    ))
    .unwrap();
    assert_eq!(answer["count"], 0);
    let answer = block_on(media(
        &store,
        &verified(seam::Request { op: "media".into(), chat: Some(CHAT.into()), id: Some("NOPE".into()), ..Default::default() }),
    ))
    .unwrap();
    assert_eq!(answer["ok"], false);
    assert_eq!(answer["error"], "whatsapp_media_not_indexed");
}

// ---- retention -----------------------------------------------------------------------------------

#[test]
fn retention_deletes_the_oldest_first_and_leaves_the_window_intact() {
    let store = Memory::new();
    let now = 1_760_000_000_000;
    let day = 86_400_000i64;
    // Two records well outside a 30-day window, one inside it.
    for (id, age_days) in [("OLD1", 100), ("OLD2", 60), ("NEW1", 1)] {
        block_on(put(&store, &text(id, now - age_days * day, "arquivo antigo"))).unwrap();
    }
    let retention = Retention::new(30);
    assert_eq!(retention.days, 30);
    // One pass, budget 1: the oldest goes and the pass says there is more.
    let pruned = block_on(prune(&store, now, retention, 1)).unwrap();
    assert_eq!(pruned, Pruned { records: 1, more: true, restored_months: 0 });
    assert!(block_on(load(&store, CHAT, "OLD1")).unwrap().is_none());
    assert!(store.keys().iter().all(|key| !key.contains("OLD1")), "the record's keys went with it");
    // A second pass takes the next one, and then stops: the one inside the window stays, and its keys.
    let pruned = block_on(prune(&store, now, retention, 10)).unwrap();
    assert_eq!(pruned, Pruned { records: 1, more: false, restored_months: 0 });
    assert!(block_on(load(&store, CHAT, "OLD2")).unwrap().is_none());
    assert!(block_on(load(&store, CHAT, "NEW1")).unwrap().is_some());
    // Nothing stale left: a third pass is free.
    assert_eq!(block_on(prune(&store, now, retention, 10)).unwrap(), Pruned::default());
    // And a wider window keeps everything that is left.
    assert_eq!(block_on(prune(&store, now, Retention::new(3650), 10)).unwrap(), Pruned::default());
    assert_eq!(Retention::new(0).days, 1, "a typo cannot stop the index");
}

#[test]
fn retention_walks_past_a_month_that_was_restored_from_its_archive() {
    // The archive (`docs/WHATSAPP-ARCHIVE.md`) loads a month back that is older than the window by
    // construction. Without the mark's range this pass would delete it again on its next tick, which is
    // the whole reason a restore is not simply a write.
    let store = Memory::new();
    let now = 1_760_000_000_000;
    let day = 86_400_000i64;
    // Two records in the restored month, one stale record from a different month, one inside the window.
    let (month, _) = seam::month::bounds(&seam::month::of(now - 400 * day)).unwrap();
    let restored_ts = month + 5 * day;
    let stale_ts = now - 200 * day;
    for (id, ts) in [("ARC1", restored_ts), ("ARC2", restored_ts + day)] {
        let mut record = text(id, ts, "mes passado");
        record.restored = true;
        block_on(put(&store, &record)).unwrap();
    }
    block_on(put(&store, &text("STALE", stale_ts, "antigo"))).unwrap();
    block_on(put(&store, &text("LIVE", now - day, "hoje"))).unwrap();
    // The mark is the month's, and it is the only thing that says the range is read-only here.
    block_on(store.set(seam::keys::archive_mark(&seam::month::of(restored_ts)).as_bytes(), br#"{"month":"x"}"#)).unwrap();

    let pruned = block_on(prune(&store, now, Retention::new(180), 10)).unwrap();
    // The stale record outside the restored range is deleted; the two restored ones are not.
    assert_eq!(pruned.records, 1, "one record was stale: {pruned:?}");
    assert_eq!(pruned.restored_months, 1, "one range was walked past: {pruned:?}");
    assert!(block_on(load(&store, CHAT, "ARC1")).unwrap().is_some(), "a restored record survives retention");
    assert!(block_on(load(&store, CHAT, "ARC2")).unwrap().is_some());
    assert!(block_on(load(&store, CHAT, "STALE")).unwrap().is_none());
    assert!(block_on(load(&store, CHAT, "LIVE")).unwrap().is_some());

    // And with the mark gone (an unload), the same records are no longer protected.
    block_on(store.del(seam::keys::archive_mark(&seam::month::of(restored_ts)).as_bytes())).unwrap();
    block_on(store.del(seam::keys::archive_mark(&seam::month::of(restored_ts)).as_bytes())).unwrap();
    let pruned = block_on(prune(&store, now, Retention::new(180), 10)).unwrap();
    assert_eq!(pruned.records, 2, "the month is ordinary data again once it is unloaded: {pruned:?}");
    assert!(block_on(load(&store, CHAT, "ARC1")).unwrap().is_none());
    assert!(block_on(load(&store, CHAT, "LIVE")).unwrap().is_some());
}

#[test]
fn a_restored_record_says_where_the_answer_came_from() {
    // The one user-visible promise of a restore: an answer built from a month that was archived says so,
    // and names the month, so a reader is never told that six-month-old text is live.
    let store = Memory::new();
    let ts = 1_760_000_000_000i64;
    let mut live = text("L1", ts, "mensagem viva");
    block_on(put(&store, &live)).unwrap();
    let live_answer = block_on(
        message(&store, &verified(seam::Request { op: "message".into(), chat: Some(CHAT.into()), id: Some("L1".into()), ..Default::default() })),
    )
    .unwrap();
    let live_message = &live_answer["message"];
    assert!(live_message.get("restored").is_none(), "a live record is not marked: {live_answer}");
    assert!(live_message.get("restored_month").is_none());

    live.restored = true;
    block_on(put(&store, &live)).unwrap();
    let restored_answer = block_on(
        message(&store, &verified(seam::Request { op: "message".into(), chat: Some(CHAT.into()), id: Some("L1".into()), ..Default::default() })),
    )
    .unwrap();
    let restored_message = &restored_answer["message"];
    assert_eq!(restored_message["restored"], true, "{restored_answer}");
    assert_eq!(restored_message["restored_month"], seam::month::of(ts));
}

#[test]
fn a_record_written_before_the_archive_existed_reads_back_as_live() {
    // `restored` is a field an older build never wrote: an absent one must mean "live", never "restored".
    let json = format!(r#"{{"chat":"{CHAT}","id":"OLD","sender":"{SENDER}","ts":1,"kind":"text","text":"oi"}}"#);
    let record: Record = serde_json::from_str(&json).unwrap();
    assert!(!record.restored);
    assert!(!record.from_history());
    let restored = text("R1", 1_760_000_000_000, "voltou");
    let mut restored = restored;
    restored.restored = true;
    let round: Record = serde_json::from_slice(&serde_json::to_vec(&restored).unwrap()).unwrap();
    assert!(round.restored, "the mark survives a round trip through the record JSON");
}

#[test]
fn repair_puts_back_the_age_key_a_crash_can_lose() {
    let store = Memory::new();
    let ts = 1_760_000_000_000;
    block_on(put(&store, &text("T1", ts, "oi"))).unwrap();
    block_on(store.del(key_age(ts, CHAT, "T1").as_bytes())).unwrap();
    assert_eq!(block_on(repair(&store, 10)).unwrap(), 1);
    assert!(block_on(store.get(key_age(ts, CHAT, "T1").as_bytes())).unwrap().is_some());
    assert_eq!(block_on(repair(&store, 10)).unwrap(), 0, "a second pass has nothing to do");
}

// ---- the age index: what a history budget and an on-demand request read --------------------------

#[test]
fn the_age_index_says_what_is_backfill_and_where_each_chat_starts() {
    let store = Memory::new();
    let base = 1_760_000_000_000;
    // Two chats, live and backfilled records interleaved, so neither order can be assumed.
    let mut live = text("L1", base + 3_000, "ao vivo");
    block_on(put(&store, &live)).unwrap();
    let mut history = text("H1", base, "do passado");
    history.source = record::SOURCE_HISTORY.into();
    block_on(put(&store, &history)).unwrap();
    let mut older = text("H2", base + 1_000, "mais antigo");
    older.source = record::SOURCE_HISTORY.into();
    block_on(put(&store, &older)).unwrap();
    live = text("L2", base + 4_000, "outro ao vivo");
    block_on(put(&store, &live)).unwrap();

    let index = block_on(age_index(&store, 10_000)).unwrap();
    assert_eq!((index.entries, index.history), (4, 2));
    assert!(!index.capped);
    assert_eq!(index.chats.len(), 1, "every record is in one chat");
    let chat = index.chat(CHAT).expect("the chat");
    assert_eq!(chat.history, 2, "only the backfilled records count against the budget");
    assert_eq!((chat.oldest_ts, chat.oldest_id.as_str()), (base, "H1"));
    assert_eq!(chat.newest_ts, base + 4_000);
    assert!(index.chat(OTHER).is_none(), "a chat with no record is not in the index");

    // The cap bounds the pass: what it saw is a floor, and it says so instead of pretending.
    let capped = block_on(age_index(&store, 2)).unwrap();
    assert_eq!((capped.entries, capped.capped), (2, true));
}

// ---- the OCR lane's mark ------------------------------------------------------------------------
//
// The loop this guards (08/11) was in the component: a terminal answer was not remembered, so the
// backlog pass re-downloaded the same images every minute. The `ocr::` tests drive the loop; these
// pin the marker itself, including the shape an older build wrote.

#[test]
fn the_ocr_mark_says_why_and_when_and_reads_an_older_build_s_marker() {
    let store = Memory::new();
    let ts = 1_760_000_000_000;
    block_on(put(&store, &image("M1", ts, ""))).unwrap();
    assert_eq!(block_on(ocr_mark(&store, CHAT, "M1")).unwrap(), None);

    // A terminal mark blocks every pass and keeps its word; `unreadable` still answers what it always
    // did, so the lane's "already answered" path needs no second convention.
    block_on(mark_unreadable(&store, CHAT, "M1", "no_text_detected")).unwrap();
    let mark = block_on(ocr_mark(&store, CHAT, "M1")).unwrap().unwrap();
    assert_eq!(mark, OcrMark::Terminal { reason: "no_text_detected".into() });
    assert!(mark.blocks(0) && mark.blocks(i64::MAX));
    assert_eq!(block_on(unreadable(&store, CHAT, "M1")).unwrap().as_deref(), Some("no_text_detected"));
    assert!(!block_on(ocr_backlog(&store, 8, 0)).unwrap().iter().any(|(_, id)| id == "M1"));

    // A retry is not an "unreadable" answer: it blocks only until its own moment, then the image is
    // in the backlog again.
    let retry = OcrMark::Retry { reason: "worker_stalled".into(), attempts: 2, next_ms: 120_000 };
    block_on(mark_ocr(&store, CHAT, "M1", &retry)).unwrap();
    assert_eq!(block_on(ocr_mark(&store, CHAT, "M1")).unwrap(), Some(retry.clone()));
    assert_eq!(block_on(unreadable(&store, CHAT, "M1")).unwrap(), None);
    assert!(!block_on(ocr_backlog(&store, 8, 119_999)).unwrap().iter().any(|(_, id)| id == "M1"));
    assert!(block_on(ocr_backlog(&store, 8, 120_000)).unwrap().iter().any(|(_, id)| id == "M1"));

    // Clearing the mark (a retry that succeeded) puts the image back in the normal state.
    block_on(clear_ocr_mark(&store, CHAT, "M1")).unwrap();
    assert_eq!(block_on(ocr_mark(&store, CHAT, "M1")).unwrap(), None);

    // A marker written by an older build is the bare word: it reads as a terminal answer.
    store_set(&store, &format!("{PREFIX}ocr/{CHAT}/M1"), "image_too_large");
    assert_eq!(block_on(ocr_mark(&store, CHAT, "M1")).unwrap(), Some(OcrMark::Terminal { reason: "image_too_large".into() }));
    assert_eq!(block_on(unreadable(&store, CHAT, "M1")).unwrap().as_deref(), Some("image_too_large"));
    // A mark of an empty value is no mark at all, not a terminal answer with no reason.
    store_set(&store, &format!("{PREFIX}ocr/{CHAT}/M1"), "");
    assert_eq!(block_on(ocr_mark(&store, CHAT, "M1")).unwrap(), None);
}

/// Write a raw value under a key, the way an older build did (the test stands in for that build).
fn store_set(store: &Memory, key: &str, value: &str) {
    use crate::index::Store as _;
    block_on(store.set(key.as_bytes(), value.as_bytes())).unwrap();
}

#[test]
fn holds_answers_whether_a_message_is_already_indexed() {
    let store = Memory::new();
    let ts = 1_760_000_000_000;
    assert!(!block_on(holds(&store, CHAT, "T1")).unwrap());
    block_on(put(&store, &text("T1", ts, "oi"))).unwrap();
    assert!(block_on(holds(&store, CHAT, "T1")).unwrap());
    // The id is scoped to its chat: the same id under another chat is a different message.
    assert!(!block_on(holds(&store, "5511777776666@s.whatsapp.net", "T1")).unwrap());
}

// ---- a legacy group id, end to end through the index -------------------------------------------
//
// The live finding (07/11): `whatsapp_search` returned a hit whose `chat` was an older group's real
// id, `<creator phone>-<creation epoch>@g.us`, and handing that same value back to
// `whatsapp_read`/`whatsapp_media`/`whatsapp_download` was refused as `bad_chat`. The fix lives in the
// seam's one rule (`wa_whatsapp_outbox::Chat::parse`); these tests are the component's half: a fixture
// index holds a message in a legacy group, and every question is asked with the chat value the search
// hit itself printed - never with a value the test rewrote.

const LEGACY: &str = "9999999999999-9999999999999@g.us";

fn legacy_image(id: &str, ts: i64, caption: &str) -> Record {
    let mut group = envelope(id, ts);
    group.chat = LEGACY.into();
    group.group = true;
    record::from_message(
        &group,
        &wap::Message {
            image_message: MessageField::some(wap::message::ImageMessage {
                mimetype: Some("image/jpeg".into()),
                caption: Some(caption.into()),
                file_length: Some(48_213),
                file_sha256: Some(vec![0xab; 32]),
                file_enc_sha256: Some(vec![0xcd; 32]),
                media_key: Some(vec![0x11; 32]),
                direct_path: Some("/v/t62.7118-24/legacy".into()),
                width: Some(1080),
                height: Some(1920),
                ..Default::default()
            }),
            ..Default::default()
        },
    )
}

#[test]
fn a_legacy_group_chat_a_search_hit_names_is_a_chat_every_question_accepts() {
    let store = Memory::new();
    let ts = 1_760_000_000_000;
    let record = legacy_image("LEG1", ts, "boleto do mes");
    assert_eq!(record.chat, LEGACY, "the index keeps the chat the hit will name");
    block_on(put(&store, &record)).unwrap();

    // 1. The search hit names exactly that chat and that id.
    let answer = block_on(search(&store, &search_request("boleto"))).unwrap();
    let hit = answer["hits"][0].clone();
    assert_eq!(hit["chat"], LEGACY);
    let chat = hit["chat"].as_str().expect("the hit names a chat").to_string();
    let id = hit["id"].as_str().expect("the hit names an id").to_string();

    // 2. `whatsapp_read`: the hit's chat validates (the seam rule) and the thread holds the message.
    let ask = verified(seam::Request { op: "read".into(), chat: Some(chat.clone()), ..Default::default() });
    assert_eq!(ask.chat.as_ref().map(|chat| chat.jid()), Some(LEGACY.to_string()));
    let answer = block_on(read(&store, &ask)).unwrap();
    assert_eq!(answer["ok"], true);
    assert_eq!(answer["chat"], LEGACY);
    assert_eq!(answer["count"], 1, "{answer}");
    assert_eq!(answer["messages"][0]["id"], id);

    // 3. `whatsapp_reactions`: accepted, and the message has no reactions yet.
    let ask = verified(seam::Request { op: "reactions".into(), chat: Some(chat.clone()), id: Some(id.clone()), ..Default::default() });
    let answer = block_on(reactions(&store, &ask)).unwrap();
    assert_eq!(answer["ok"], true);
    assert_eq!(answer["chat"], LEGACY);
    assert_eq!(answer["count"], 0);

    // 4. `whatsapp_media`: accepted, and it is the media of that message.
    let ask = verified(seam::Request { op: "media".into(), chat: Some(chat.clone()), id: Some(id.clone()), ..Default::default() });
    let answer = block_on(media(&store, &ask)).unwrap();
    assert_eq!(answer["ok"], true);
    assert_eq!(answer["chat"], LEGACY);
    assert_eq!(answer["kind"], "image");
    assert_eq!(answer["downloadable"], true);

    // 5. `whatsapp_download`: the query half the guest runs before it asks for a client
    //    (`index::download_plan`) accepts the chat the hit printed, finds that message and its
    //    downloadable media - and applies the caller's bound. A refusal here is the live
    //    `whatsapp_download_failed bad_chat`.
    let ask = verified(seam::Request { op: "download".into(), chat: Some(chat.clone()), id: Some(id.clone()), ..Default::default() });
    let plan = block_on(download_plan(&store, &ask, seam::MAX_DOWNLOAD_BYTES)).unwrap();
    let target = match plan {
        DownloadPlan::Fetch(target) => target,
        DownloadPlan::Refused(answer) => panic!("the hit's chat refused the download: {answer}"),
    };
    assert_eq!((target.chat.as_str(), target.id.as_str()), (LEGACY, id.as_str()));
    assert!(target.media.downloadable);
    assert_eq!(target.media.kind, "image");
    // The same request with a bound smaller than the media is answered, not fetched.
    let small = verified(seam::Request {
        op: "download".into(),
        chat: Some(chat.clone()),
        id: Some(id.clone()),
        max_bytes: Some(1_024),
        ..Default::default()
    });
    match block_on(download_plan(&store, &small, seam::MAX_DOWNLOAD_BYTES)).unwrap() {
        DownloadPlan::Refused(answer) => {
            assert_eq!(answer["ok"], false);
            assert_eq!(answer["error"], "whatsapp_download_download_too_large");
        }
        DownloadPlan::Fetch(_) => panic!("a 48 KiB image must not fit in 1 KiB"),
    }
    assert_eq!(
        chat::jid(&chat).expect("the one conversion the download step uses").to_string(),
        LEGACY
    );

    // 6. `whatsapp_backfill`: the anchor the index offers names the same chat, and the conversion that
    //    hands it to the phone (`chat::jid`) accepts it - the live path counted a refused anchor.
    let anchors = block_on(history::anchors(&store, Some(&chat), 50)).unwrap();
    assert_eq!(anchors.len(), 1);
    assert_eq!(anchors[0].chat, LEGACY);
    assert_eq!(anchors[0].id, id);
    assert_eq!(chat::jid(&anchors[0].chat).expect("the phone can be asked about it").to_string(), LEGACY);
    // A chat the index holds nothing for is still asked about by the exact value the caller named.
    let cold = block_on(history::anchors(&store, Some(LEGACY), 50)).unwrap();
    assert_eq!(cold[0].chat, LEGACY);

    // 7. The refusals did not move: an address-shaped string is judged by the exact-JID rule and
    //    nothing else, so a hyphen on a person's server, two hyphens, an empty half and an unsendable
    //    server are still refused with the same word the seam and `chat::jid` use - in every op.
    for (bad, code) in [
        ("9999999999999-9999999999999@s.whatsapp.net", "bad_chat"),
        ("1-2-3@g.us", "bad_chat"),
        ("-1@g.us", "bad_chat"),
        ("1-@g.us", "bad_chat"),
        ("120363000000000001@newsletter", "unsupported_chat"),
    ] {
        for op in ["read", "contacts", "message", "backfill"] {
            let request = seam::Request { op: op.into(), chat: Some(bad.into()), ..Default::default() };
            assert_eq!(request.validate().unwrap_err().code, code, "{op} {bad}");
        }
        assert_eq!(chat::jid(bad).unwrap_err(), code, "{bad}");
    }
    // A bare number has no `@`, so it is a *name* to resolve, never an address to invent: `read` and
    // `contacts` accept it as a question (`chat_name`), and the one JID conversion still refuses to
    // turn it into a chat, which is what keeps a send from guessing a recipient.
    let numeric = seam::Request { op: "read".into(), chat: Some("5511999999999".into()), ..Default::default() };
    assert_eq!(numeric.validate().expect("a name to resolve").chat_name.as_deref(), Some("5511999999999"));
    assert_eq!(chat::jid("5511999999999").unwrap_err(), "bad_chat");
    let send = seam::Request { op: "search".into(), chat: Some("5511999999999".into()), q: Some("x".into()), ..Default::default() };
    assert_eq!(send.validate().unwrap_err().code, "bad_chat", "a search filter is an exact chat");
    // Nothing was written for a refused request, and the thread is still the one message.
    let answer = block_on(read(&store, &verified(seam::Request { op: "read".into(), chat: Some(LEGACY.into()), ..Default::default() }))).unwrap();
    assert_eq!(answer["count"], 1, "{answer}");
}

// ---- names: the question #117 was opened for -----------------------------------------------------

const LAURA: &str = "5511977777777@s.whatsapp.net";
const BRUNO: &str = "5511966666666@s.whatsapp.net";
const LAURA_TWO: &str = "5511955555555@s.whatsapp.net";
const FAMILY: &str = "120363000000000777@g.us";

/// One message from `name` in a direct chat: the shape a contact's own message arrives in (the sender
/// is the chat, and the envelope carries their push name).
fn direct(chat: &str, name: &str, id: &str, ts: i64, body: &str) -> Record {
    let envelope = Envelope {
        chat: chat.into(),
        id: id.into(),
        sender: chat.into(),
        own: false,
        group: false,
        ts,
        received: ts + 5,
        push_name: name.into(),
        ..Default::default()
    };
    let message = wap::Message { conversation: Some(body.to_string()), ..Default::default() };
    record::from_message(&envelope, &message)
}

fn base() -> i64 {
    1_760_000_000_000
}

#[test]
fn a_name_resolves_to_the_one_chat_that_carries_it() {
    let store = Memory::new();
    block_on(put(&store, &direct(LAURA, "Laura", "L1", base(), "bom dia"))).unwrap();
    block_on(put(&store, &direct(BRUNO, "Bruno", "B1", base() + 1, "oi"))).unwrap();

    // Case and accents do not matter: the name is folded the same way a token index folds it.
    let answer = block_on(contacts(&store, &verified(seam::Request { op: "contacts".into(), q: Some("LAURA".into()), ..Default::default() }))).unwrap();
    assert_eq!(answer["ok"], true, "{answer}");
    assert_eq!(answer["count"], 1, "{answer}");
    assert_eq!(answer["chat"], LAURA, "one exact match is also the chat");
    assert_eq!(answer["ambiguous"], false);
    let candidate = &answer["candidates"][0];
    assert_eq!(candidate["chat"], LAURA);
    assert_eq!(candidate["type"], "person");
    assert_eq!(candidate["name"], "Laura");
    assert_eq!(candidate["name_source"], "push_name");
    assert_eq!(candidate["confidence"], "exact");
    assert_eq!(candidate["jid"], LAURA);
    assert!(candidate["at_iso"].as_str().unwrap().ends_with('Z'), "a time a reader can place: {candidate}");

    // A partial spelling is a different confidence, and says so instead of pretending to be exact.
    let partial = block_on(contacts(&store, &verified(seam::Request { op: "contacts".into(), q: Some("lau".into()), ..Default::default() }))).unwrap();
    assert_eq!(partial["count"], 1, "{partial}");
    assert_eq!(partial["candidates"][0]["confidence"], "prefix");
    assert_eq!(partial["candidates"][0]["matched"], "Laura");

    // With no query at all the answer is the chats the index knows, most recently heard from first.
    let all = block_on(contacts(&store, &verified(seam::Request { op: "contacts".into(), ..Default::default() }))).unwrap();
    assert_eq!(all["count"], 2, "{all}");
    assert_eq!(all["candidates"][0]["chat"], BRUNO, "the newest chat first");
}

#[test]
fn two_chats_with_the_same_name_are_candidates_and_never_a_pick() {
    let store = Memory::new();
    block_on(put(&store, &direct(LAURA, "Laura", "L1", base(), "bom dia"))).unwrap();
    block_on(put(&store, &direct(LAURA_TWO, "Laura", "L2", base() + 1, "oi"))).unwrap();

    let answer = block_on(contacts(&store, &verified(seam::Request { op: "contacts".into(), q: Some("Laura".into()), ..Default::default() }))).unwrap();
    assert_eq!(answer["count"], 2, "{answer}");
    assert_eq!(answer["ambiguous"], true);
    assert!(answer.get("chat").is_none(), "two Lauras: no chat is picked for the caller");

    // A read by that name refuses with the candidates rather than reading whichever sorted first.
    let ambiguous = block_on(read(&store, &verified(seam::Request { op: "read".into(), chat: Some("Laura".into()), ..Default::default() }))).unwrap();
    assert_eq!(ambiguous["ok"], false, "{ambiguous}");
    assert_eq!(ambiguous["error"], "whatsapp_read_chat_ambiguous");
    let candidates = ambiguous["candidates"].as_array().unwrap();
    assert_eq!(candidates.len(), 2);
    // Reading one of them by its exact JID is the way on, and it works.
    let one = block_on(read(&store, &verified(seam::Request { op: "read".into(), chat: Some(LAURA.into()), ..Default::default() }))).unwrap();
    assert_eq!(one["count"], 1, "{one}");
}

#[test]
fn a_name_nobody_carries_is_an_honest_none() {
    let store = Memory::new();
    block_on(put(&store, &direct(LAURA, "Laura", "L1", base(), "bom dia"))).unwrap();

    let answer = block_on(contacts(&store, &verified(seam::Request { op: "contacts".into(), q: Some("Zeca".into()), ..Default::default() }))).unwrap();
    assert_eq!(answer["count"], 0, "{answer}");
    assert!(answer.get("chat").is_none());
    assert!(answer["note"].as_str().unwrap().contains("no chat in this index"), "{answer}");

    let missing = block_on(read(&store, &verified(seam::Request { op: "read".into(), chat: Some("Zeca".into()), ..Default::default() }))).unwrap();
    assert_eq!(missing["error"], "whatsapp_read_chat_not_found");
}

#[test]
fn a_group_is_named_by_the_subject_this_node_fetched_and_by_nothing_else() {
    let store = Memory::new();
    // A group message carries the *sender's* push name; a group is never named after a member.
    block_on(put(&store, &text("G1", base(), "bom dia a todos"))).unwrap();
    let unnamed = block_on(contacts(&store, &verified(seam::Request { op: "contacts".into(), q: Some("Ana".into()), ..Default::default() }))).unwrap();
    assert_eq!(unnamed["candidates"][0]["chat"], CHAT);
    assert_eq!(unnamed["candidates"][0]["name"], "", "a group has no name until its subject is fetched");
    assert_eq!(unnamed["candidates"][0]["name_source"], "jid");
    assert_eq!(unnamed["candidates"][0]["type"], "group");

    // Once the subject is known (the alert path fetches it), it is the name - and a query finds it.
    block_on(set_subject(&store, CHAT, "Família")).unwrap();
    let named = block_on(contacts(&store, &verified(seam::Request { op: "contacts".into(), q: Some("familia".into()), ..Default::default() }))).unwrap();
    assert_eq!(named["count"], 1, "{named}");
    assert_eq!(named["candidates"][0]["name"], "Família");
    assert_eq!(named["candidates"][0]["name_source"], "group_subject");
    assert_eq!(named["candidates"][0]["chat"], CHAT);
}

#[test]
fn read_by_name_answers_with_the_header_and_the_message_shape() {
    let store = Memory::new();
    let mut reply = direct(LAURA, "Laura", "L2", base() + 60_000, "claro, pode ligar");
    reply.quoted = "L1".into();
    block_on(put(&store, &direct(LAURA, "Laura", "L1", base(), "bom dia, tudo bem?"))).unwrap();
    block_on(put(&store, &reply)).unwrap();

    let answer = block_on(read(&store, &verified(seam::Request { op: "read".into(), chat: Some("Laura".into()), ..Default::default() }))).unwrap();
    assert_eq!(answer["ok"], true, "{answer}");
    // The header names the chat, in words, and says what kind of chat it is.
    assert_eq!(answer["header"]["chat"], LAURA);
    assert_eq!(answer["header"]["name"], "Laura");
    assert_eq!(answer["header"]["name_source"], "push_name");
    assert_eq!(answer["header"]["type"], "person");
    assert_eq!(answer["header"]["unread"], serde_json::Value::Null, "no receipt is indexed, so no count is invented");
    // How the name became a chat is in the answer, so the caller can see it was not a guess.
    assert_eq!(answer["resolved"]["from"], "Laura");
    assert_eq!(answer["resolved"]["to"], LAURA);
    assert_eq!(answer["resolved"]["confidence"], "exact");
    // Newest first, and every message carries who/when/what in the one shape.
    let messages = answer["messages"].as_array().unwrap();
    assert_eq!(messages.len(), 2);
    assert_eq!(messages[0]["id"], "L2");
    assert_eq!(messages[0]["from"]["name"], "Laura");
    assert_eq!(messages[0]["from"]["jid"], LAURA);
    assert_eq!(messages[0]["from"]["own"], false);
    assert!(messages[0]["at_local"].as_str().unwrap().len() == 16, "YYYY-MM-DD HH:MM: {messages:?}");
    assert!(messages[0]["at_iso"].as_str().unwrap().ends_with('Z'));
    // The reply quotes the message it answers, and the quote is the stored snippet.
    assert_eq!(messages[0]["reply_to"]["id"], "L1");
    assert_eq!(messages[0]["reply_to"]["quote"], "bom dia, tudo bem?");
    // No protobuf noise and no key material in an answer.
    assert!(messages[0].get("media_key").is_none());
    assert!(messages[0].get("direct_path").is_none());
}

#[test]
fn paging_walks_a_thread_once_with_the_cursor_the_answer_gives() {
    let store = Memory::new();
    for (index, body) in ["um", "dois", "tres"].iter().enumerate() {
        let id = format!("P{index}");
        block_on(put(&store, &direct(LAURA, "Laura", &id, base() + index as i64 * 1000, body))).unwrap();
    }
    let first = block_on(read(&store, &verified(seam::Request { op: "read".into(), chat: Some(LAURA.into()), limit: Some(2), ..Default::default() }))).unwrap();
    assert_eq!(first["count"], 2, "{first}");
    assert_eq!(first["has_more"], true);
    assert_eq!(first["messages"][0]["id"], "P2", "newest first");
    let cursor = first["next_before"].as_str().unwrap().to_string();
    assert_eq!(cursor, "P1");

    let second = block_on(read(&store, &verified(seam::Request { op: "read".into(), chat: Some(LAURA.into()), limit: Some(2), before: Some(cursor), ..Default::default() }))).unwrap();
    assert_eq!(second["count"], 1, "{second}");
    assert_eq!(second["has_more"], false);
    assert_eq!(second["messages"][0]["id"], "P0");
    // The pages do not overlap: every message is read exactly once.
    assert!(second["messages"].as_array().unwrap().iter().all(|message| message["id"] != "P2"));
}

#[test]
fn a_search_hit_names_the_chat_and_the_sender() {
    let store = Memory::new();
    block_on(put(&store, &direct(LAURA, "Laura", "S1", base(), "o boleto vence amanha"))).unwrap();
    let answer = block_on(search(&store, &search_request("boleto"))).unwrap();
    let hit = &answer["hits"][0];
    assert_eq!(hit["chat"], LAURA);
    assert_eq!(hit["chat_name"], "Laura", "a hit that only carried the JID made a reader ask who that is");
    assert_eq!(hit["sender_name"], "Laura");
    assert_eq!(hit["from"]["name"], "Laura");
    assert!(hit["at_iso"].as_str().unwrap().ends_with('Z'));
    assert!(hit.get("quoted").is_none(), "not a reply, so no reply key");
}

// ---- an index that holds messages and no names: the 13/11 account node ---------------------------

/// Every chat the index knows, asked the way a model asks it with no name to resolve.
fn every_chat() -> seam::Verified {
    verified(seam::Request { op: "contacts".into(), ..Default::default() })
}

fn named(q: &str) -> seam::Verified {
    verified(seam::Request { op: "contacts".into(), q: Some(q.into()), ..Default::default() })
}

/// A store with a write budget, and a count of what it allowed: the component's kv grant is a token
/// bucket (`kv.write`'s `rate` in `policies/default.json`, which answers `capability_rate_limited`),
/// and this is the part of it an index write meets. Deletes are charged too - the host gates them
/// with the same capability.
struct Budgeted {
    inner: Memory,
    left: std::cell::Cell<usize>,
    writes: std::cell::Cell<usize>,
}

impl Budgeted {
    fn new(writes: usize) -> Budgeted {
        Budgeted { inner: Memory::new(), left: std::cell::Cell::new(writes), writes: std::cell::Cell::new(0) }
    }

    fn charge(&self) -> Result<(), String> {
        if self.left.get() == 0 {
            return Err("capability_rate_limited".to_string());
        }
        self.left.set(self.left.get() - 1);
        self.writes.set(self.writes.get() + 1);
        Ok(())
    }
}

impl Store for Budgeted {
    fn get<'a>(&'a self, key: &'a [u8]) -> impl std::future::Future<Output = Result<Option<Vec<u8>>, String>> + 'a {
        self.inner.get(key)
    }

    fn set<'a>(&'a self, key: &'a [u8], value: &'a [u8]) -> impl std::future::Future<Output = Result<(), String>> + 'a {
        let charged = self.charge();
        async move {
            charged?;
            self.inner.set(key, value).await
        }
    }

    fn del<'a>(&'a self, key: &'a [u8]) -> impl std::future::Future<Output = Result<(), String>> + 'a {
        let charged = self.charge();
        async move {
            charged?;
            self.inner.del(key).await
        }
    }

    fn scan<'a>(
        &'a self,
        prefix: &'a [u8],
        cursor: Option<Vec<u8>>,
        limit: usize,
    ) -> impl std::future::Future<Output = Result<Page, String>> + 'a {
        self.inner.scan(prefix, cursor, limit)
    }
}

/// The records of a chat whose name side is missing, the way the account node's index arrived: the
/// messages are all there and not one `ix/ct/` row exists.
fn delete_names(store: &Memory) -> usize {
    let names: Vec<String> = store.keys().into_iter().filter(|key| key.starts_with("ix/ct/")).collect();
    for key in &names {
        block_on(store.del(key.as_bytes())).unwrap();
    }
    names.len()
}

#[test]
fn an_index_of_messages_with_no_names_says_which_half_is_missing_and_rebuilds_it() {
    let store = Memory::new();
    block_on(put(&store, &direct(LAURA, "Laura", "L1", base(), "bom dia"))).unwrap();
    block_on(put(&store, &direct(BRUNO, "Bruno", "B1", base() + 60_000, "oi"))).unwrap();
    // The control: the live path names both chats.
    assert_eq!(block_on(contacts(&store, &every_chat())).unwrap()["count"], 2);

    // The shape the account node reported on 13/11: 57310 stored entries, messages arriving, and
    // `contacts` answering `count: 0` to every query - including the one that names no chat.
    assert_eq!(delete_names(&store), 2);
    let empty = block_on(contacts(&store, &every_chat())).unwrap();
    assert_eq!(empty["count"], 0, "{empty}");
    assert_eq!(empty["index"]["chats"], 0);
    assert_eq!(empty["index"]["messages"], 2, "the messages are there, and the answer says so: {empty}");
    assert_eq!(empty["index"]["names"], "pending", "and names the missing half: {empty}");
    let note = empty["note"].as_str().unwrap();
    assert!(note.contains("2 message(s) are indexed"), "{note}");
    assert!(!note.contains("the index only knows names it has seen on messages"), "{note}");

    // One bounded walk over the records already stored is all it takes.
    let pass = block_on(backfill_cards(&store, 10)).unwrap();
    assert!(pass.done);
    assert_eq!((pass.visited, pass.chats), (2, 2));
    let rebuilt = block_on(contacts(&store, &every_chat())).unwrap();
    assert_eq!(rebuilt["count"], 2, "{rebuilt}");
    assert_eq!(rebuilt["candidates"][0]["chat"], BRUNO, "newest first, the same order the live path gives");
    assert_eq!(rebuilt["candidates"][0]["name"], "Bruno");
    assert_eq!(rebuilt["index"]["names"], "ready");
    // And the name resolves again, to the chat it always meant.
    let laura = block_on(contacts(&store, &named("Laura"))).unwrap();
    assert_eq!(laura["chat"], LAURA, "{laura}");
    assert_eq!(laura["count"], 1);
    // A walk that already finished costs one read, not another scan.
    let again = block_on(backfill_cards(&store, 10)).unwrap();
    assert_eq!((again.visited, again.chats, again.done), (0, 0, true));
}

#[test]
fn a_write_budget_that_runs_out_costs_the_record_and_never_the_name() {
    // One write allowed, so exactly one of a message's writes can land. It has to be the chat's card:
    // the name is what `whatsapp_contacts` reads, and the record is what `backfill_cards` can rebuild
    // nothing of - so the budget is spent on the name, and the record's refusal is a line, not a
    // silent hole in the index's answers.
    let store = Budgeted::new(1);
    let refused = block_on(put(&store, &direct(LAURA, "Laura", "L1", base(), "bom dia"))).unwrap_err();
    assert!(refused.contains("capability_rate_limited"), "{refused}");
    assert_eq!(store.writes.get(), 1);
    assert!(!store.inner.keys().iter().any(|key| key.starts_with("ix/m/")), "the record was refused");
    let answer = block_on(contacts(&store, &named("Laura"))).unwrap();
    assert_eq!(answer["count"], 1, "the chat is still a chat the index knows: {answer}");
    assert_eq!(answer["chat"], LAURA);

    // The same message with the budget it actually costs lands whole, and the count is the number the
    // component's grant (`per_minute: 240`) is spent against.
    let roomy = Budgeted::new(100);
    block_on(put(&roomy, &direct(LAURA, "Laura", "L1", base(), "bom dia"))).unwrap();
    assert_eq!(roomy.writes.get(), 8, "{:?}", roomy.inner.keys());
}

#[test]
fn the_name_walk_is_bounded_and_resumes_where_it_stopped() {
    let store = Memory::new();
    for (i, chat) in [LAURA, BRUNO].iter().enumerate() {
        for step in 0..2 {
            let id = format!("{i}{step}");
            block_on(put(&store, &direct(chat, "Nome", &id, base() + (i as i64 * 10 + step) * 1_000, "oi"))).unwrap();
        }
    }
    delete_names(&store);
    assert_eq!(block_on(backfill_state(&store)).unwrap(), "pending");

    // One record per pass: a restored index of fifty thousand messages must not be folded in one
    // tick, because every card it writes is charged to the same grant the live lane is spending.
    let first = block_on(backfill_cards(&store, 1)).unwrap();
    assert_eq!(first.visited, 1);
    assert_eq!(first.chats, 1);
    assert!(!first.done);
    assert_eq!(block_on(backfill_state(&store)).unwrap(), "rebuilding");

    let mut passes = 1;
    let mut visited = first.visited;
    loop {
        let pass = block_on(backfill_cards(&store, 1)).unwrap();
        passes += 1;
        visited += pass.visited;
        if pass.done {
            break;
        }
        assert!(passes < 20, "the walk must end: {passes} passes");
    }
    assert_eq!(visited, 4, "every record folded exactly once");
    assert_eq!(passes, 5, "four records and the pass that finds the end");
    assert_eq!(block_on(backfill_state(&store)).unwrap(), "ready");
    // A subject this node fetched survives the walk: both paths read-modify-write the same row.
    block_on(set_subject(&store, CHAT, "Família")).unwrap();
    let named_group = block_on(contacts(&store, &named("familia"))).unwrap();
    assert_eq!(named_group["chat"], CHAT, "{named_group}");
}

#[test]
fn a_shared_contact_card_names_the_chat_its_number_belongs_to() {
    let store = Memory::new();
    // A chat whose person never wrote a push name: the index holds the message and no name at all.
    block_on(put(&store, &direct(LAURA, "", "L1", base(), "oi"))).unwrap();
    let before = block_on(contacts(&store, &named("Laura"))).unwrap();
    assert_eq!(before["count"], 0, "{before}");

    // Somebody shares that person's card in the group: a name and the number it belongs to.
    let mut card = text("C1", base() + 1_000, "contato da Laura");
    card.contacts = vec![record::Contact { name: "Laura".into(), phones: vec!["5511977777777".into()] }];
    block_on(put(&store, &card)).unwrap();
    let after = block_on(contacts(&store, &named("Laura"))).unwrap();
    assert_eq!(after["count"], 1, "{after}");
    assert_eq!(after["chat"], LAURA);
    assert_eq!(after["candidates"][0]["name_source"], "contact_card", "{after}");
    assert_eq!(after["candidates"][0]["name"], "Laura");

    // The name the person writes on their own messages still outranks it.
    block_on(put(&store, &direct(LAURA, "Laura Souza", "L2", base() + 2_000, "bom dia"))).unwrap();
    let own = block_on(contacts(&store, &named("Laura"))).unwrap();
    assert_eq!(own["candidates"][0]["name"], "Laura Souza", "{own}");
    assert_eq!(own["candidates"][0]["name_source"], "push_name");
    // A card naming a number this index has no chat for does not invent one.
    let mut stranger = text("C2", base() + 3_000, "outro contato");
    stranger.contacts = vec![record::Contact { name: "Zeca".into(), phones: vec!["5511900000000".into()] }];
    block_on(put(&store, &stranger)).unwrap();
    let zeca = block_on(contacts(&store, &named("Zeca"))).unwrap();
    assert_eq!(zeca["count"], 0, "{zeca}");
}

#[test]
fn a_refused_write_is_retried_a_bounded_number_of_times_and_then_said() {
    // The lane that uses this (`guest::index_inbox`) is wasm-only, so the decision is here where
    // `cargo test` reaches it: the refusal is the kv grant's bucket, which refills in a minute.
    assert_eq!(refused(0), Refused::Retry);
    assert_eq!(refused(RETRY_LIMIT - 1), Refused::Retry);
    assert_eq!(refused(RETRY_LIMIT), Refused::Drop);
    assert_eq!(refused(u8::MAX), Refused::Drop);
    assert_eq!(RETRY_LIMIT, 8);
}

// ---- the address book the phone syncs (13/11: `q: "Laura"` answered 0) ---------------------------

/// The contact the operator saved on their phone, as the app-state action carries it: the saved name,
/// the address it applies to, and the two identities WhatsApp knows that person by.
fn saved(jid: &str, name: &str, lid: &str, pn: &str, at: i64) -> AddressBookContact {
    AddressBookContact {
        jids: vec![jid.to_string(), lid.to_string(), pn.to_string()],
        name: name.to_string(),
        numbers: vec![pn.to_string()],
        at,
    }
}

#[test]
fn an_address_book_name_finds_the_chat_the_phone_saved_it_under() {
    let store = Memory::new();
    // The person talks under a push name of their own choosing; the operator saved them as `Laura ❤️`.
    block_on(put(&store, &direct(LAURA, "Lou", "L1", base(), "bom dia"))).unwrap();
    assert_eq!(block_on(contacts(&store, &named("Laura"))).unwrap()["count"], 0, "nothing carries that name yet");

    block_on(set_contact(&store, &saved(LAURA, "Laura ❤️", "", "5511977777777@s.whatsapp.net", base() + 1))).unwrap();

    // Case is ignored, the emoji is ignored, and the answer says where the name came from.
    let answer = block_on(contacts(&store, &named("laura"))).unwrap();
    assert_eq!(answer["count"], 1, "{answer}");
    assert_eq!(answer["chat"], LAURA);
    let candidate = &answer["candidates"][0];
    assert_eq!(candidate["matched"], "Laura ❤️");
    assert_eq!(candidate["matched_source"], "address_book");
    assert_eq!(candidate["confidence"], "exact", "the emoji is not part of the name: {answer}");
    assert_eq!(candidate["name"], "Laura ❤️", "the operator's own word for the person is what they see");
    assert_eq!(candidate["name_source"], "address_book");
    assert_eq!(candidate["jid"], LAURA);
    // The push name the person writes is still in the answer, with its source.
    let names = candidate["names"].as_array().expect("names");
    assert!(names.iter().any(|entry| entry["name"] == "Lou" && entry["source"] == "push_name"), "{candidate}");
    assert!(names.iter().any(|entry| entry["name"] == "Laura ❤️" && entry["source"] == "address_book"), "{candidate}");
    // `index.address_book` is the count that tells "no sync yet" from "no such name".
    assert_eq!(answer["index"]["address_book"], 1, "{answer}");
}

#[test]
fn an_accented_saved_name_matches_without_the_accent() {
    let store = Memory::new();
    block_on(put(&store, &direct(BRUNO, "", "B1", base(), "oi"))).unwrap();
    let mut contact = saved(BRUNO, "Família Andrade", "", BRUNO, base() + 1);
    contact.numbers = vec!["5511966666666".into()];
    block_on(set_contact(&store, &contact)).unwrap();

    for spelling in ["familia andrade", "FAMÍLIA ANDRADE", "Familia Andrade"] {
        let answer = block_on(contacts(&store, &named(spelling))).unwrap();
        assert_eq!(answer["count"], 1, "{spelling}: {answer}");
        assert_eq!(answer["chat"], BRUNO);
        assert_eq!(answer["candidates"][0]["matched_source"], "address_book");
        assert_eq!(answer["candidates"][0]["confidence"], "exact", "{spelling}: {answer}");
    }
    // A prefix is still a prefix, and says so.
    let partial = block_on(contacts(&store, &named("familia"))).unwrap();
    assert_eq!(partial["candidates"][0]["confidence"], "prefix", "{partial}");
}

#[test]
fn a_phone_number_resolves_its_chat_in_any_formatting() {
    let store = Memory::new();
    // The chat is knowledge the index got from messages only: no address book, no name at all.
    block_on(put(&store, &direct(LAURA, "", "L1", base(), "oi"))).unwrap();
    block_on(put(&store, &direct(BRUNO, "", "B1", base() + 1, "oi"))).unwrap();

    for number in ["5511977777777", "+55 11 97777-7777", "+55 (11) 97777-7777", "55 11 97777 7777", "(11) 97777-7777", "11 97777-7777"] {
        let answer = block_on(contacts(&store, &named(number))).unwrap();
        assert_eq!(answer["count"], 1, "{number}: {answer}");
        assert_eq!(answer["chat"], LAURA, "{number}: {answer}");
        assert_eq!(answer["candidates"][0]["confidence"], "exact", "{number}: {answer}");
        assert_eq!(answer["candidates"][0]["matched_source"], "number", "{number}: {answer}");
    }
    // A fragment is not a number: it is a partial match, which the answer admits.
    let fragment = block_on(contacts(&store, &named("77777"))).unwrap();
    assert_eq!(fragment["candidates"][0]["confidence"], "partial", "{fragment}");
}

#[test]
fn a_lid_chat_is_found_by_the_phone_number_the_index_learned_for_it() {
    let store = Memory::new();
    // A DM WhatsApp journals under its hidden `@lid`, with the sender's other address on the envelope:
    // that is where the index learns which phone number this chat is.
    let mut lid = direct(LID, "Lou", "L1", base(), "oi");
    lid.sender_alt = LAURA.into();
    block_on(put(&store, &lid)).unwrap();

    let by_number = block_on(contacts(&store, &named("+55 11 97777-7777"))).unwrap();
    assert_eq!(by_number["count"], 1, "{by_number}");
    assert_eq!(by_number["chat"], LID, "the chat the messages are in, not a chat invented from the number");
    assert_eq!(by_number["candidates"][0]["jid"], LID);
    // And the address book's own PN mapping says the same thing, without a second message. The action
    // names the phone number FIRST here, as the server does when the contact's JID is the PN and the
    // chat is the LID: the fold must still land on the LID chat the messages are in, not on a card it
    // invents for the PN (which would answer a chat holding nothing).
    block_on(set_contact(&store, &saved(LAURA, "Laura ❤️", LID, LAURA, base() + 1))).unwrap();
    let by_name = block_on(contacts(&store, &named("laura"))).unwrap();
    assert_eq!(by_name["chat"], LID, "{by_name}");
    let by_number = block_on(contacts(&store, &named("5511977777777"))).unwrap();
    assert_eq!(by_number["chat"], LID, "{by_number}");
}

#[test]
fn a_business_name_is_found_as_a_profile_name() {
    let store = Memory::new();
    // A bakery whose owner's push name is a first name; WhatsApp's own name for the account is the one
    // the operator would search for.
    let mut bakery = direct(BRUNO, "Ana", "B1", base(), "pão quentinho");
    bakery.business = "Padaria do Zé".into();
    block_on(put(&store, &bakery)).unwrap();

    let answer = block_on(contacts(&store, &named("padaria do ze"))).unwrap();
    assert_eq!(answer["count"], 1, "{answer}");
    assert_eq!(answer["chat"], BRUNO);
    assert_eq!(answer["candidates"][0]["matched"], "Padaria do Zé");
    assert_eq!(answer["candidates"][0]["matched_source"], "profile");
    assert_eq!(answer["candidates"][0]["name"], "Padaria do Zé", "the business name outranks the push name for a business");
    assert_eq!(answer["candidates"][0]["name_source"], "profile");
}

#[test]
fn the_address_book_and_the_messages_meet_in_either_order() {
    // A sync that arrives before the first message, and one that arrives after it, end in the same card:
    // `card_touch` folds the address-book row it finds, and `set_contact` folds into the cards it finds.
    let before = Memory::new();
    block_on(set_contact(&before, &saved(LAURA, "Laura ❤️", "", LAURA, base()))).unwrap();
    block_on(put(&before, &direct(LAURA, "Lou", "L1", base() + 1, "oi"))).unwrap();

    let after = Memory::new();
    block_on(put(&after, &direct(LAURA, "Lou", "L1", base() + 1, "oi"))).unwrap();
    block_on(set_contact(&after, &saved(LAURA, "Laura ❤️", "", LAURA, base()))).unwrap();

    for store in [&before, &after] {
        let answer = block_on(contacts(store, &named("laura"))).unwrap();
        assert_eq!(answer["count"], 1, "{answer}");
        assert_eq!(answer["candidates"][0]["name"], "Laura ❤️");
        assert_eq!(answer["candidates"][0]["name_source"], "address_book");
        // The person's own name is still there beside it.
        assert_eq!(block_on(contacts(store, &named("lou"))).unwrap()["count"], 1, "the push name survives the sync");
    }
}

#[test]
fn renaming_or_removing_a_contact_replaces_what_the_index_knew() {
    let store = Memory::new();
    block_on(put(&store, &direct(LAURA, "Lou", "L1", base(), "oi"))).unwrap();
    block_on(set_contact(&store, &saved(LAURA, "Laura ❤️", "", LAURA, base() + 1))).unwrap();
    assert_eq!(block_on(contacts(&store, &named("laura"))).unwrap()["count"], 1);

    // The operator renames the contact: the old saved name stops matching, the new one starts.
    block_on(set_contact(&store, &saved(LAURA, "Mãe da Juju", "", LAURA, base() + 2))).unwrap();
    assert_eq!(block_on(contacts(&store, &named("laura"))).unwrap()["count"], 0, "a renamed contact is not found by the old name");
    let renamed = block_on(contacts(&store, &named("mae da juju"))).unwrap();
    assert_eq!(renamed["count"], 1, "{renamed}");
    assert_eq!(renamed["chat"], LAURA);

    // The operator removes them from the address book: the name goes, the mapping and the push name stay.
    block_on(set_contact(&store, &saved(LAURA, "", "", LAURA, base() + 3))).unwrap();
    assert_eq!(block_on(contacts(&store, &named("mae da juju"))).unwrap()["count"], 0);
    assert_eq!(block_on(contacts(&store, &named("lou"))).unwrap()["count"], 1, "the person's own name is not ours to drop");
    assert_eq!(block_on(contacts(&store, &named("5511977777777"))).unwrap()["count"], 1, "the number still resolves");
}

#[test]
fn a_name_match_with_no_sync_says_so_in_the_index_block() {
    let store = Memory::new();
    block_on(put(&store, &direct(LAURA, "Laura", "L1", base(), "bom dia"))).unwrap();

    let none = block_on(contacts(&store, &named("Zeca"))).unwrap();
    assert_eq!(none["count"], 0, "{none}");
    assert_eq!(none["index"]["address_book"], 0, "{none}");
    let note = none["note"].as_str().expect("a note");
    assert!(note.contains("no address book has been synced"), "{note}");

    // Once the address book is here, the same empty answer is a fact about the names and not about a
    // sync that never came - the two used to be one sentence (13/11).
    block_on(set_contact(&store, &saved(BRUNO, "Bruno", "", BRUNO, base() + 1))).unwrap();
    let synced = block_on(contacts(&store, &named("Zeca"))).unwrap();
    assert_eq!(synced["index"]["address_book"], 1, "{synced}");
    let note = synced["note"].as_str().expect("a note");
    assert!(note.contains("1 address-book contact(s)"), "{note}");
    assert!(!note.contains("no address book has been synced"), "the sync is no longer the missing half: {note}");
}

#[test]
fn a_push_name_change_is_a_name_the_index_knows() {
    let store = Memory::new();
    block_on(put(&store, &direct(LAURA, "", "L1", base(), "oi"))).unwrap();
    assert_eq!(block_on(contacts(&store, &named("Laurinha"))).unwrap()["count"], 0);
    block_on(set_push_name(&store, &LAURA, "Laurinha", base() + 1)).unwrap();
    let answer = block_on(contacts(&store, &named("laurinha"))).unwrap();
    assert_eq!(answer["count"], 1, "{answer}");
    assert_eq!(answer["candidates"][0]["name_source"], "push_name");
    // A group is never named after a member, so a push name does not name a group's card either.
    assert!(block_on(set_push_name(&store, CHAT, "Alguém", base() + 2)).is_ok());
    assert_eq!(block_on(contacts(&store, &named("alguem"))).unwrap()["count"], 0);
}

#[test]
fn a_rebuild_of_the_name_side_keeps_the_address_book() {
    // `backfill_cards` walks messages (`ix/m`) and rewrites every card. The address book is not in the
    // records, so a rebuild that only folded records would drop the operator's own names.
    let store = Memory::new();
    block_on(put(&store, &direct(LAURA, "Lou", "L1", base(), "oi"))).unwrap();
    block_on(set_contact(&store, &saved(LAURA, "Laura ❤️", "", LAURA, base() + 1))).unwrap();
    // Forget every card, the way an index that arrived without its name side looks.
    for chat in [LAURA] {
        use crate::index::Store as _;
        block_on(store.del(key_card(chat).as_bytes())).unwrap();
    }
    assert_eq!(block_on(contacts(&store, &every_chat())).unwrap()["index"]["chats"], 0);

    let pass = block_on(backfill_cards(&store, 64)).unwrap();
    assert_eq!(pass.done, true);
    let rebuilt = block_on(contacts(&store, &named("laura"))).unwrap();
    assert_eq!(rebuilt["count"], 1, "{rebuilt}");
    assert_eq!(rebuilt["candidates"][0]["name_source"], "address_book");
    assert_eq!(rebuilt["candidates"][0]["messages"], 1, "the message the rebuild folded is still counted");
}

#[test]
fn a_name_that_is_only_an_emoji_is_still_a_name() {
    // Dropping the emoji from a comparison is what makes `laura` find `Laura ❤️`; taken literally it
    // would leave a chat called `🔔` with no name at all. The rule is "the emoji goes while something
    // else remains", on both sides of the comparison.
    let store = Memory::new();
    block_on(put(&store, &direct(LAURA, "🔔", "L1", base(), "oi"))).unwrap();
    let answer = block_on(contacts(&store, &named("🔔"))).unwrap();
    assert_eq!(answer["count"], 1, "{answer}");
    assert_eq!(answer["chat"], LAURA);
    assert_eq!(answer["candidates"][0]["confidence"], "exact", "{answer}");

    // And the emoji-decorated saved name still matches the bare name, exactly. The chat has to exist
    // first: an address-book row names a chat, it never invents one (the index drops a card with no
    // message only when nobody wrote one, which is the same rule `/mcp` applies to a chat nobody has).
    block_on(put(&store, &direct(BRUNO, "", "B1", base() + 500, "oi"))).unwrap();
    block_on(set_contact(&store, &saved(BRUNO, "Bruno 🎸", "", BRUNO, base() + 1))).unwrap();
    let named_ = block_on(contacts(&store, &named("bruno"))).unwrap();
    assert_eq!(named_["chat"], BRUNO, "{named_}");
    assert_eq!(named_["candidates"][0]["confidence"], "exact", "{named_}");
}

#[test]
fn the_address_book_is_asked_for_once_per_store() {
    // WhatsApp sends a linked device the contact catalogue when it pairs, and only asks again if the
    // device does. So a store that was paired by a build which did not keep the names has to ask ONCE:
    // the mark is per store (`ix/ab/sync`), and the pipeline asks only while it is absent.
    let store = Memory::new();
    assert_eq!(block_on(address_sync_done(&store)).unwrap(), false);
    block_on(mark_address_sync(&store)).unwrap();
    assert_eq!(block_on(address_sync_done(&store)).unwrap(), true);
}

// ---- the collection the device already holds (14/11: `q: "Laura"` answered 0, `address_book: 1`) ----

/// A fake server and store, in one: the collection's persisted version, whether it holds a sync key, and
/// how many times the component ASKED.
///
/// The counting is the point. The 14/11 night deploy logged one request and then nothing for 25 minutes
/// with the index still empty, because `process_sync_task` can return without contacting the server at
/// all. So this fake behaves like the real one in the only way that matters: it hands over the address
/// book ONLY when it was asked, and it says how many asks it took. A component that assumes one request
/// is one answer passes a test written against a fake that answers by itself; it fails this one.
struct FakePhone {
    /// The collection's persisted version - what `snapshot_is_stale` reads.
    version: std::cell::Cell<u64>,
    /// Whether an app-state sync key exists to decode an answer with.
    keys: std::cell::Cell<bool>,
    /// How many full-sync requests reached this "server".
    asked: std::cell::Cell<u32>,
    /// What this phone's address book holds, released on the next request.
    book: Vec<AddressBookContact>,
}

impl FakePhone {
    fn new(version: u64, book: Vec<AddressBookContact>) -> FakePhone {
        FakePhone {
            version: std::cell::Cell::new(version),
            keys: std::cell::Cell::new(true),
            asked: std::cell::Cell::new(0),
            book,
        }
    }

    fn asked(&self) -> u32 {
        self.asked.get()
    }

    /// Answer the request, if there was one: the snapshot is applied the way `whatsapp_rust` applies it -
    /// the collection advances to the version the snapshot carries, and each contact action arrives with
    /// `from_full_sync`, which is what the component's `contact_inbox` turns into `set_contact` plus
    /// `ix/ab/full`.
    ///
    /// With no request outstanding it answers NOTHING and changes nothing: that is a server that was not
    /// asked, and it is the state the 14/11 deploy was actually in.
    fn answer(&self, store: &Memory, answered: &std::cell::Cell<u32>) {
        if self.asked.get() == answered.get() {
            return;
        }
        answered.set(self.asked.get());
        if self.book.is_empty() {
            // A snapshot that carries no contact: the collection still advances, so the next decision
            // reads a version above zero. Nothing is written to the index.
            self.version.set(9);
            return;
        }
        for contact in &self.book {
            block_on(set_contact(store, contact)).unwrap();
        }
        block_on(mark_address_full(store)).unwrap();
        block_on(mark_address_sync(store)).unwrap();
        self.version.set(9);
    }
}

impl AddressBookAppState for FakePhone {
    fn persisted_version(&self, collection: &str) -> impl std::future::Future<Output = Result<u64, String>> {
        assert_eq!(collection, CONTACT_COLLECTION);
        let version = self.version.get();
        async move { Ok(version) }
    }

    fn reset_collection(&self, collection: &str) -> impl std::future::Future<Output = Result<(), String>> {
        // The reset is only ever allowed to touch the collection that carries contacts.
        assert_eq!(collection, CONTACT_COLLECTION);
        self.version.set(0);
        async move { Ok(()) }
    }

    fn has_sync_keys(&self) -> impl std::future::Future<Output = Result<bool, String>> {
        let keys = self.keys.get();
        async move { Ok(keys) }
    }

    fn request_full_sync(&self, collection: &str) -> impl std::future::Future<Output = Result<(), String>> {
        assert_eq!(collection, CONTACT_COLLECTION);
        self.asked.set(self.asked.get() + 1);
        async move { Ok(()) }
    }
}

#[test]
fn the_book_arrives_only_because_the_component_asked() {
    // The whole 13/11 -> 14/11 story in one test. The store persists `regular` at v9 and holds no
    // contact; with nothing asked, the index learns NOTHING - a fake that answers by itself would hide
    // the defect that actually shipped. Then one supervised step resets the version (v9 would get the
    // snapshot dropped as stale), asks, and the answer puts the saved name and the number in the index.
    let store = Memory::new();
    let answered = std::cell::Cell::new(0);
    let phone = FakePhone::new(9, vec![saved(LAURA, "Laura ❤️", "", LAURA, base())]);
    block_on(put(&store, &direct(LAURA, "Lou", "", base(), "bom dia"))).unwrap();

    // Not asked yet: the server says nothing and the index holds no name.
    phone.answer(&store, &answered);
    assert_eq!(block_on(contacts(&store, &named("laura"))).unwrap()["count"], 0);
    assert_eq!(block_on(address_count(&store, COUNT_CAP)).unwrap(), (0, false));

    let mut reset_performed = false;
    let step = block_on(advance_address_book(&store, &phone, &mut reset_performed)).unwrap();
    assert_eq!(step, AddressBookStep::Requested { attempts: 1, reset: true }, "v9 was hiding it: reset, then ask");
    assert_eq!(phone.asked(), 1);
    assert_eq!(phone.version.get(), 0, "the persisted version is what would have got the snapshot dropped");
    assert!(reset_performed);

    // The server answers the request it was given.
    phone.answer(&store, &answered);
    let answer = block_on(contacts(&store, &named("laura"))).unwrap();
    assert_eq!(answer["count"], 1, "{answer}");
    assert_eq!(answer["chat"], LAURA);
    assert_eq!(answer["candidates"][0]["name_source"], "address_book");
    assert_eq!(block_on(address_count(&store, COUNT_CAP)).unwrap(), (1, false));

    // And the recovery is over: a further tick asks for nothing at all.
    let before = phone.asked();
    assert_eq!(block_on(advance_address_book(&store, &phone, &mut reset_performed)).unwrap(), AddressBookStep::Received);
    assert_eq!(phone.asked(), before, "a store that has the book asks nothing");
}

#[test]
fn a_request_the_server_never_answers_is_asked_again() {
    // The live failure, reproduced: the request goes out, the server never answers (in the field, a
    // connect-time sync held the collection and `process_sync_task` returned at `debug!`), and the index
    // stays empty. One call is not allowed to be the end of it - the loop must ask again, and only the
    // arrival of the book may settle it.
    let store = Memory::new();
    let answered = std::cell::Cell::new(0);
    let phone = FakePhone::new(9, vec![saved(LAURA, "Laura ❤️", "", LAURA, base())]);
    // The chat exists: an address-book row names a chat, it never invents one.
    block_on(put(&store, &direct(LAURA, "Lou", "", base(), "bom dia"))).unwrap();
    let mut reset_performed = false;

    assert_eq!(
        block_on(advance_address_book(&store, &phone, &mut reset_performed)).unwrap(),
        AddressBookStep::Requested { attempts: 1, reset: true }
    );
    // No answer: the next tick must ask AGAIN, not report success. It also must not reset a second time
    // for nothing - the version is already zero, which is what `reset: false` says.
    assert_eq!(
        block_on(advance_address_book(&store, &phone, &mut reset_performed)).unwrap(),
        AddressBookStep::Requested { attempts: 2, reset: false }
    );
    assert_eq!(phone.asked(), 2, "a request is not an answer, so it is asked again");

    // When it finally answers, the book lands and the loop stops.
    phone.answer(&store, &answered);
    assert_eq!(block_on(contacts(&store, &named("laura"))).unwrap()["count"], 1);
    assert_eq!(block_on(advance_address_book(&store, &phone, &mut reset_performed)).unwrap(), AddressBookStep::Received);
}

#[test]
fn a_phone_that_loses_patience_is_said_once_and_not_forever() {
    // Per connection the budget is bounded, and the last word is a line that can be read rather than an
    // endless silent loop: the 14/11 deploy produced 25 minutes of silence and no diagnosis.
    let store = Memory::new();
    let phone = FakePhone::new(9, vec![saved(LAURA, "Laura", "", LAURA, base())]);
    let mut reset_performed = false;
    for attempt in 1..=ADDRESS_ATTEMPT_CAP {
        let step = block_on(advance_address_book(&store, &phone, &mut reset_performed)).unwrap();
        assert_eq!(step, AddressBookStep::Requested { attempts: attempt, reset: attempt == 1 }, "{step:?}");
    }
    assert_eq!(block_on(address_attempts(&store)).unwrap(), ADDRESS_ATTEMPT_CAP);
    assert_eq!(
        block_on(advance_address_book(&store, &phone, &mut reset_performed)).unwrap(),
        AddressBookStep::Exhausted { attempts: ADDRESS_ATTEMPT_CAP }
    );
    // A new connection gets its own budget: the fetch that was skipped was skipped against work in
    // flight on that connection, and a reconnect is what clears it - the budget, and the caller's memory
    // of having reset the version, which is `guest`'s `AddressBookRun` cleared on a drop.
    block_on(clear_address_attempts(&store)).unwrap();
    reset_performed = false;
    // `reset: false`, because the version is already zero: there is nothing left for a reset to uncover,
    // and resetting again every connection would be a write with no question behind it.
    assert_eq!(
        block_on(advance_address_book(&store, &phone, &mut reset_performed)).unwrap(),
        AddressBookStep::Requested { attempts: 1, reset: false }
    );
}

#[test]
fn a_store_with_no_sync_key_says_so_instead_of_asking_forever() {
    // Without an app-state sync key the snapshot cannot be decoded at all, and no request produces the
    // key: it is shared by the phone. So this is the one state that must be NAMED, and asking again would
    // be the silence with extra steps.
    let store = Memory::new();
    let phone = FakePhone::new(9, vec![saved(LAURA, "Laura", "", LAURA, base())]);
    phone.keys.set(false);
    let mut reset_performed = false;
    assert_eq!(
        block_on(advance_address_book(&store, &phone, &mut reset_performed)).unwrap(),
        AddressBookStep::KeysMissing
    );
    assert_eq!(phone.asked(), 0, "nothing can be decoded, so nothing is requested");
    assert_eq!(block_on(address_attempts(&store)).unwrap(), 0);
}

#[test]
fn a_collection_that_synced_back_is_a_fact_and_not_a_conclusion() {
    // The snapshot applies, the collection advances to v9 again, and no contact action arrives. The step
    // reports EXACTLY that: `Synced { version }`. It deliberately does not say the account has no saved
    // contacts - the 14/11 deploy said so, on this state alone, about an operator whose phone had his wife
    // saved. It settles the loop (asking again would bring the same answer) and leaves the meaning to the
    // caller, which reports the events it counted.
    let store = Memory::new();
    let answered = std::cell::Cell::new(0);
    let phone = FakePhone::new(9, Vec::new());
    let mut reset_performed = false;
    assert_eq!(
        block_on(advance_address_book(&store, &phone, &mut reset_performed)).unwrap(),
        AddressBookStep::Requested { attempts: 1, reset: true }
    );
    phone.answer(&store, &answered);
    assert_eq!(phone.version.get(), 9, "the snapshot applied and carried nothing");
    assert_eq!(
        block_on(advance_address_book(&store, &phone, &mut reset_performed)).unwrap(),
        AddressBookStep::Synced { version: 9 }
    );
    // Settled for good: the next call asks nothing, because the empty book is the book.
    let before = phone.asked();
    assert_eq!(block_on(advance_address_book(&store, &phone, &mut reset_performed)).unwrap(), AddressBookStep::Received);
    assert_eq!(phone.asked(), before);
}

#[test]
fn the_address_book_decision_answers_every_measured_state() {
    // (persisted version, book received, attempts, keys, reset performed) -> what one attempt must do.
    let states = [
        // Never synced, key present: the ordinary first-sync path. Version 0 is already "fresh".
        ((0, false, 0, true, false), AddressBookStep::Requested { attempts: 0, reset: false }),
        // The 14/11 store: v9, nothing received, nothing asked yet. Reset first or the snapshot is stale.
        ((9, false, 0, true, false), AddressBookStep::Requested { attempts: 0, reset: true }),
        // Asked before and still v9: ask again, and reset again only if a sync wrote the version back.
        ((9, false, 2, true, true), AddressBookStep::Synced { version: 9 }),
        ((9, false, 2, true, false), AddressBookStep::Requested { attempts: 2, reset: true }),
        // Budget spent on this connection.
        ((0, false, ADDRESS_ATTEMPT_CAP, true, true), AddressBookStep::Exhausted { attempts: ADDRESS_ATTEMPT_CAP }),
        // No key: named, never retried.
        ((9, false, 0, false, false), AddressBookStep::KeysMissing),
        // The book arrived: nothing is ever owed again, whatever the bookkeeping says.
        ((9, true, 0, true, false), AddressBookStep::Received),
        ((9, true, ADDRESS_ATTEMPT_CAP, false, true), AddressBookStep::Received),
    ];
    for ((version, full, attempts, keys, reset), expected) in states {
        assert_eq!(
            address_book_decision(version, full, attempts, keys, reset),
            expected,
            "version={version} full={full} attempts={attempts} keys={keys} reset={reset}"
        );
    }
}

#[test]
fn the_address_book_count_counts_people_and_not_its_own_marks() {
    // 14/11's `address_book: 1` was the mark, not a person: `ix/ab/sync` shares the prefix with the
    // contact rows, so the answer said the index knew one address-book contact while it knew none -
    // and the note a model reads ("this node knows 1 address-book contact(s)") was false with it.
    let store = Memory::new();
    block_on(mark_address_sync(&store)).unwrap();
    block_on(mark_address_full(&store)).unwrap();
    block_on(bump_address_attempts(&store)).unwrap();
    assert_eq!(block_on(address_count(&store, COUNT_CAP)).unwrap(), (0, false), "marks are not contacts");

    block_on(set_contact(&store, &saved(LAURA, "Laura ❤️", "", LAURA, base()))).unwrap();
    assert_eq!(block_on(address_count(&store, COUNT_CAP)).unwrap(), (1, false), "one person, one row");

    // And the answer a model reads says so, rather than describing a sync that never happened.
    let answer = block_on(contacts(&store, &named("zzz nobody"))).unwrap();
    assert_eq!(answer["index"]["address_book"], 1, "{answer}");
    assert!(!answer["note"].as_str().unwrap_or_default().contains("no address book has been synced"), "{answer}");
}

#[test]
fn a_received_mark_from_a_collection_that_carries_no_contact_is_not_a_received_book() {
    // The live store's state, exactly: the 9a5414f5 build wrote `ix/ab/full` after asking `regular`, which
    // carries no contact. A bare flag would bind this build to that claim and it would ask nothing at all -
    // a deploy that changes the code and does nothing. The mark stores the collection it came from, so `1`
    // reads as "not received from critical_unblock_low" and the recovery runs.
    let store = Memory::new();
    block_on(store.set(key_address_full().as_bytes(), b"1")).unwrap();
    assert_eq!(block_on(address_full_done(&store)).unwrap(), false, "a legacy flag proves nothing");
    let phone = FakePhone::new(9, vec![saved(LAURA, "Laura ❤️", "", LAURA, base())]);
    let mut reset_performed = false;
    assert_eq!(
        block_on(advance_address_book(&store, &phone, &mut reset_performed)).unwrap(),
        AddressBookStep::Requested { attempts: 1, reset: true },
        "the recovery is not blocked by a mark from the wrong collection"
    );
    // And the mark this build writes does bind it.
    block_on(mark_address_full(&store)).unwrap();
    assert_eq!(block_on(address_full_done(&store)).unwrap(), true);
}

#[test]
fn the_recovery_writes_contacts_and_nothing_about_the_pairing() {
    // What a reset-then-snapshot leaves behind, at the index's own level: address rows and cards, and no
    // key of the device, the sync keys or the versions. `set_contact` is the ONLY writer a delivered
    // contact action reaches, and this is the proof that it touches nothing else - the reason the
    // recovery cannot change the pairing is that it has no call that could.
    let store = Memory::new();
    block_on(put(&store, &direct(LID, "Lou", "L1", base(), "oi"))).unwrap();
    let before: Vec<String> = store.keys();
    assert!(before.iter().all(|key| key.starts_with("ix/")), "{before:?}");

    block_on(set_contact(&store, &saved(LAURA, "Laura ❤️", LID, LAURA, base() + 1))).unwrap();

    let after: Vec<String> = store.keys();
    let added: Vec<&String> = after.iter().filter(|key| !before.contains(key)).collect();
    assert!(added.iter().all(|key| key.starts_with("ix/ab/")), "only address rows are added: {added:?}");
    for forbidden in ["dev", "sync/", "ver/", "id/", "ses/", "pk/", "lid/"] {
        assert!(
            after.iter().all(|key| !key.starts_with(forbidden)),
            "a contact action must not write `{forbidden}`: {after:?}"
        );
    }
    // The name and the number it maps the `@lid` chat to both answer, from one action: the `pnJid` on the
    // contact action is the only place a `@lid` chat's phone number comes from.
    assert_eq!(block_on(contacts(&store, &named("laura"))).unwrap()["chat"], LID);
    assert_eq!(block_on(contacts(&store, &named("5511977777777"))).unwrap()["chat"], LID);
}

// ---- which collection carries contacts, and what a snapshot of each one does ------------------------

/// The collection this component asks for is the one the PROTOCOL names, asserted against the schema
/// registry rather than against memory.
///
/// This is the test that would have caught the 14/11 night deploy before it happened. The component asked
/// `regular`, which is where chat actions live; `CONTACT` and `LID_CONTACT` are declared on
/// `critical_unblock_low`, so the request could only ever be answered "not here" - and the log turned that
/// into a claim about the operator's phone.
#[test]
fn the_contact_collection_is_the_one_the_schema_registry_names() {
    let contact = wacore_appstate::schemas::CONTACT.collection.as_str();
    let lid_contact = wacore_appstate::schemas::LID_CONTACT.collection.as_str();
    assert_eq!(contact, lid_contact, "both contact actions share one collection");
    assert_eq!(CONTACT_COLLECTION, contact, "the collection asked for is the one `contact` is written to");
    assert_ne!(CONTACT_COLLECTION, "regular", "`regular` carries chat actions, not the address book");
    // And the action names a report would show are the schema's own.
    assert_eq!(wacore_appstate::schemas::CONTACT.name, "contact");
    assert_eq!(wacore_appstate::schemas::LID_CONTACT.name, "lid_contact");
}

/// The request this component sends names the contact collection - asserted on the value that becomes the
/// wire attribute, not on a label in a log line.
///
/// This is the test the 05:50 deploy needed. That build logged `full critical_unblock_low snapshot
/// requested` and every request went out as `regular`, because the guest mapped `CONTACT_COLLECTION` to
/// `WAPatchName::Regular`. The library writes this value straight into the IQ
/// (`attr("name", name.as_str())`), so an assertion here is an assertion about the outgoing request: the
/// collection name the server sees, and therefore which collection's snapshot comes back.
#[test]
fn the_outgoing_request_names_the_collection_that_carries_contacts() {
    use wacore::appstate::patch_decode::WAPatchName;
    let asked = contact_patch_name();
    // What `<collection name="...">` carries.
    assert_eq!(asked.as_str(), CONTACT_COLLECTION, "the request must name the collection this index keeps the book for");
    assert_eq!(asked, WAPatchName::CriticalUnblockLow);
    assert_ne!(asked, WAPatchName::Regular, "`regular` is what made every answer a stale `regular` snapshot");
    // Derived from the registry, so it cannot drift from what the protocol declares.
    assert_eq!(asked.as_str(), wacore_appstate::schemas::CONTACT.collection.as_str());
    assert_eq!(asked.as_str(), wacore_appstate::schemas::LID_CONTACT.collection.as_str());
}

/// One fixture snapshot: the collection it arrived in, the contact actions it carries, and how many other
/// action kinds it carried (chat pins, archives, ...), which this index never reads.
struct Fixture {
    collection: &'static str,
    contacts: Vec<AddressBookContact>,
    other_actions: u32,
}

/// Apply a fixture the way `guest`'s contact inbox does: a `contact` action becomes an address row, and an
/// action from any other collection is not an address-book action at all, so it writes nothing.
fn apply(store: &Memory, snapshot: &Fixture) -> usize {
    let mut written = 0;
    if snapshot.collection == CONTACT_COLLECTION {
        for contact in &snapshot.contacts {
            block_on(set_contact(store, contact)).unwrap();
            written += 1;
        }
        if written > 0 {
            block_on(mark_address_full(store)).unwrap();
        }
    }
    written
}

#[test]
fn a_snapshot_of_the_contact_collection_puts_the_saved_name_and_number_in_the_index() {
    let store = Memory::new();
    block_on(put(&store, &direct(LID, "Lou", "L1", base(), "oi"))).unwrap();

    // The phone's saved contact, as `critical_unblock_low` carries it: the name, the `@lid` address it also
    // knows her by, and the PN that is her phone number.
    let snapshot = Fixture {
        collection: CONTACT_COLLECTION,
        contacts: vec![saved(LAURA, "Laura ❤️", LID, LAURA, base() + 1)],
        other_actions: 0,
    };
    assert_eq!(apply(&store, &snapshot), 1);
    // TWO rows for ONE person: `address_count` counts rows, one per address, and this contact is known by
    // both a PN and a LID - which is the pair that makes the number lookup below work.
    assert_eq!(block_on(address_count(&store, COUNT_CAP)).unwrap(), (2, false));

    // Both the name and the number answer, and both point at the chat the messages are in.
    assert_eq!(block_on(contacts(&store, &named("laura"))).unwrap()["chat"], LID);
    assert_eq!(block_on(contacts(&store, &named("5511977777777"))).unwrap()["chat"], LID);
}

#[test]
fn a_snapshot_of_a_chat_collection_writes_no_address_row() {
    // `regular` carries pins, archives, mutes and stars. It is NOT where contacts live, so a full snapshot
    // of it can arrive, apply, carry forty actions and still leave this index with no name - which is
    // exactly what the 14/11 deploy observed, and why asking it was the bug.
    let store = Memory::new();
    block_on(put(&store, &direct(LAURA, "Lou", "", base(), "bom dia"))).unwrap();
    let snapshot = Fixture {
        collection: "regular",
        contacts: vec![saved(LAURA, "Laura ❤️", "", LAURA, base() + 1)],
        other_actions: 40,
    };
    // Forty chat actions and still not one address row: the collection is where a full snapshot can
    // succeed and say nothing about the address book.
    assert_eq!(snapshot.other_actions, 40);
    assert_eq!(apply(&store, &snapshot), 0, "no contact action arrives from a chat collection");
    assert_eq!(block_on(address_count(&store, COUNT_CAP)).unwrap(), (0, false));
    assert_eq!(block_on(contacts(&store, &named("laura"))).unwrap()["count"], 0, "the push name is all there is");
}

#[test]
fn the_two_contact_collection_snapshots_tell_the_apart_states_apart() {
    // The two fixtures side by side, which is the difference the log line has to preserve: one collection
    // delivers the book, the other delivers chat actions. A component that asked the wrong one has the
    // second state and no right to describe the first.
    let delivered = Memory::new();
    block_on(put(&delivered, &direct(LAURA, "Lou", "", base(), "oi"))).unwrap();
    let hit = Fixture { collection: CONTACT_COLLECTION, contacts: vec![saved(LAURA, "Laura", "", LAURA, base())], other_actions: 0 };
    assert_eq!(apply(&delivered, &hit), 1);

    let missed = Memory::new();
    block_on(put(&missed, &direct(LAURA, "Lou", "", base(), "oi"))).unwrap();
    let miss = Fixture { collection: "regular", contacts: vec![saved(LAURA, "Laura", "", LAURA, base())], other_actions: 40 };
    assert_eq!(apply(&missed, &miss), 0);

    assert_eq!(block_on(contacts(&delivered, &named("laura"))).unwrap()["count"], 1);
    assert_eq!(block_on(contacts(&missed, &named("laura"))).unwrap()["count"], 0);
    // A store that received nothing has received nothing: `ix/ab/full` is not written for it, so the
    // component keeps asking instead of settling on a collection that is not the address book.
    assert_eq!(block_on(address_full_done(&delivered)).unwrap(), true);
    assert_eq!(block_on(address_full_done(&missed)).unwrap(), false);
}
