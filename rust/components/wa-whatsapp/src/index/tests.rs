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
    assert_eq!(pruned, Pruned { records: 1, more: true });
    assert!(block_on(load(&store, CHAT, "OLD1")).unwrap().is_none());
    assert!(store.keys().iter().all(|key| !key.contains("OLD1")), "the record's keys went with it");
    // A second pass takes the next one, and then stops: the one inside the window stays, and its keys.
    let pruned = block_on(prune(&store, now, retention, 10)).unwrap();
    assert_eq!(pruned, Pruned { records: 1, more: false });
    assert!(block_on(load(&store, CHAT, "OLD2")).unwrap().is_none());
    assert!(block_on(load(&store, CHAT, "NEW1")).unwrap().is_some());
    // Nothing stale left: a third pass is free.
    assert_eq!(block_on(prune(&store, now, retention, 10)).unwrap(), Pruned::default());
    // And a wider window keeps everything that is left.
    assert_eq!(block_on(prune(&store, now, Retention::new(3650), 10)).unwrap(), Pruned::default());
    assert_eq!(Retention::new(0).days, 1, "a typo cannot stop the index");
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

    // 7. The refusals did not move: a bare number, a hyphen on a person's server, two hyphens, an empty
    //    half and an unsendable server are still refused, with the same word the seam uses.
    for (bad, code) in [
        ("5511999999999", "bad_chat"),
        ("9999999999999-9999999999999@s.whatsapp.net", "bad_chat"),
        ("1-2-3@g.us", "bad_chat"),
        ("-1@g.us", "bad_chat"),
        ("1-@g.us", "bad_chat"),
        ("120363000000000001@newsletter", "unsupported_chat"),
    ] {
        let request = seam::Request { op: "read".into(), chat: Some(bad.into()), ..Default::default() };
        assert_eq!(request.validate().unwrap_err().code, code, "{bad}");
        assert_eq!(chat::jid(bad).unwrap_err(), code, "{bad}");
    }
    // Nothing was written for a refused request, and the thread is still the one message.
    let answer = block_on(read(&store, &verified(seam::Request { op: "read".into(), chat: Some(LEGACY.into()), ..Default::default() }))).unwrap();
    assert_eq!(answer["count"], 1, "{answer}");
}
