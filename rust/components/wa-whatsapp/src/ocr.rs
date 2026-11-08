//! OCR for image messages: which record is worth reading, what to do with the answer, and where the
//! text goes.
//!
//! Parity is the point of this module. The old bridge (`connectors/whatsapp`, `docs/WHATSAPP-OCR.md`)
//! downloads an image with its bounded media client, runs the **same** worker script
//! (`scripts/whatsapp-ocr-local.py`), and stores the recognized text in the message row, where a
//! literal query finds it. The component does the same three steps through the kernel's reader
//! (`wa:kernel/vision`), with the same bounds:
//!
//! * **20 MiB per image**, refused before the download and again before the reader - the worker's own
//!   `image_too_large` bound. A bigger photo costs a line in the log, not 40 MiB of RAM.
//! * **No text in any log line.** Callers log the job, the chat, the id and *counts*; the text goes to
//!   [`index::attach_text`] and nowhere else. The reader's own refusals (`no_text_detected`, …) are
//!   words, not content.
//! * **A permanent answer stays permanent.** A screenshot with no words, a media type that is not an
//!   image, and an unprovisioned worker are all answers: retrying them re-downloads a photo to learn
//!   the same thing. A stalled or restarted worker is not (the kernel already retries it once).
//!
//! Everything here is pure or store-only (no host call and no wasm target requirement), so a native
//! test drives the identical code with a fake reader and `index::Memory`; the guest supplies the
//! reader (`vision::read`) and the bytes (`client.download_from_params`) as arguments.

use crate::index::{self, Store};
use crate::record::{self, Record};

/// Largest image this component will OCR, the old bridge's bound (`record::MAX_MEDIA_BYTES` is the
/// same number: what the pipeline may download at all is what it may read).
pub const MAX_IMAGE_BYTES: u64 = record::MAX_MEDIA_BYTES;

/// Why one indexed record was not read. Every word here is metadata: none of them can carry text.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Skip {
    /// Not an image message, and not a document whose media type says image.
    NotAnImage,
    /// The record kept no media at all (view-once, ephemeral, or nothing to point at).
    NoMedia,
    /// The record has a direct path but no media key: nothing can fetch it.
    NotDownloadable,
    /// The sender took the message back.
    Deleted,
    /// An earlier pass already attached text.
    AlreadyRead,
    /// Larger than [`MAX_IMAGE_BYTES`].
    TooLarge,
    /// The reader answered with no legible text.
    NoText,
    /// The record is gone (retention, or a revoke that landed while the image was being read).
    NotFound,
    /// An earlier pass decided this image has nothing legible in it (or is too large) and the index
    /// remembers the word, so it is not downloaded again (`index::mark_unreadable`).
    Unreadable,
}

impl Skip {
    /// The stable word a log line and a telemetry note carry.
    pub fn word(&self) -> &'static str {
        match self {
            Skip::NotAnImage => "not_an_image",
            Skip::NoMedia => "no_media",
            Skip::NotDownloadable => "not_downloadable",
            Skip::Deleted => "deleted",
            Skip::AlreadyRead => "already_read",
            Skip::TooLarge => "image_too_large",
            Skip::NoText => "no_text_detected",
            Skip::NotFound => "not_found",
            Skip::Unreadable => "unreadable",
        }
    }
}

/// The result of one OCR attempt.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// The text was attached to the record and indexed.
    Attached { chars: u64, bytes: u64 },
    /// Nothing was read, and nothing should be retried.
    Skipped(Skip),
    /// The reader (or the store) answered a failure another attempt cannot change.
    Refused(String),
    /// A failure worth another attempt later: a full queue (`again`), a worker restarting, a
    /// download that timed out.
    Retry(String),
}

impl Outcome {
    /// A one-word state for a log line.
    pub fn word(&self) -> &'static str {
        match self {
            Outcome::Attached { .. } => "attached",
            Outcome::Skipped(skip) => skip.word(),
            Outcome::Refused(_) => "refused",
            Outcome::Retry(_) => "retry",
        }
    }

    /// Should the caller put the record back in its queue? Only a retryable failure says yes.
    pub fn retry(&self) -> bool {
        matches!(self, Outcome::Retry(_))
    }

    /// The reason a [`Refused`](Outcome::Refused)/[`Retry`](Outcome::Retry) carries, bounded, so a
    /// worker's line can never become a long log field.
    pub fn reason(&self) -> Option<&str> {
        match self {
            Outcome::Refused(reason) | Outcome::Retry(reason) => Some(reason),
            _ => None,
        }
    }
}

/// Is this record an image worth reading? No I/O and no length check of the blob (only the size the
/// record already knows), because this is asked when the message arrives, before anything is fetched.
///
/// Images and documents whose media type is an image: the old bridge OCRed `media_kind='image'`, and a
/// scanned receipt sent "as a document" is the same screenshot with a filename, so both are read. A
/// PDF is not: that needs a text extractor this component does not have.
pub fn wanted(record: &Record) -> Result<(), Skip> {
    if record.deleted {
        return Err(Skip::Deleted);
    }
    if !record.ocr.is_empty() {
        return Err(Skip::AlreadyRead);
    }
    // The kind first: a text message has no media at all, and "not an image" is the truer word for
    // it than "no media".
    if record.kind != "image" && record.kind != "document" {
        return Err(Skip::NotAnImage);
    }
    let Some(media) = record.media.as_ref() else { return Err(Skip::NoMedia) };
    let image_kind = media.kind == "image" || (media.kind == "document" && is_image_mime(&media.mime));
    if !image_kind {
        return Err(Skip::NotAnImage);
    }
    if !media.downloadable {
        return Err(Skip::NotDownloadable);
    }
    if media.size > MAX_IMAGE_BYTES {
        return Err(Skip::TooLarge);
    }
    Ok(())
}

/// `image/jpeg`, `image/png; q=1`… but not `application/pdf`.
pub fn is_image_mime(mime: &str) -> bool {
    let base = mime.split(';').next().unwrap_or("").trim().to_ascii_lowercase();
    base.starts_with("image/")
}

/// The media type to hand the reader: what the record kept, else the one WhatsApp images always are.
pub fn mime(record: &Record) -> String {
    let kept = record.media.as_ref().map(|media| media.mime.trim().to_string()).unwrap_or_default();
    if kept.is_empty() {
        "image/jpeg".to_string()
    } else {
        kept
    }
}

/// Is another attempt at the same image pointless? These are the reader's own words
/// (`wit/kernel-v2`'s `vision.read`, `scripts/whatsapp-ocr-local.py`) plus this component's local
/// failures. A stalled or timed-out worker is *not* here: the kernel retries it once itself, and a
/// fresh worker may read the same pixels.
pub fn permanent(reason: &str) -> bool {
    let word = reason.split(':').next().unwrap_or(reason);
    matches!(
        word,
        "no_text_detected"
            | "image_too_large"
            | "unsupported_media"
            | "ocr_text_too_long"
            | "rapidocr_missing"
            | "offline_model_unavailable"
            | "unsupported_mode"
            | "not_an_image"
            | "no_media"
            | "not_downloadable"
            | "deleted"
            | "already_read"
            | "not_found"
            // The reader is not provisioned on this node: retrying cannot provision it.
            | "ocr_python_missing"
            | "ocr_worker_missing"
            | "ocr_worker_not_configured"
    )
}

/// Read one image and attach what it says to its index record.
///
/// `reader` is the host call the guest supplies, `(bytes, mime) -> Result<text, reason>`; the size
/// rule, the skip decisions and the attach are this function's, so the component and the tests run the
/// same code. The text is trimmed (the worker already strips it) and attached through
/// [`index::attach_text`], which bounds it to [`record::MAX_TEXT`] - the same field a search already
/// reads, so a photo becomes findable by what it shows with no new query path.
pub async fn run<S, R, F>(store: &S, record: &Record, bytes: Vec<u8>, reader: R) -> Outcome
where
    S: Store,
    R: FnOnce(Vec<u8>, String) -> F,
    F: std::future::Future<Output = Result<String, String>>,
{
    if let Err(skip) = wanted(record) {
        return Outcome::Skipped(skip);
    }
    let bytes_len = bytes.len() as u64;
    if bytes_len == 0 {
        return Outcome::Refused("empty_image".into());
    }
    // The record's advertised size and the bytes that arrived are two different claims: both are
    // checked, because a lying `file_length` must not become a 40 MiB worker input either.
    if bytes_len > MAX_IMAGE_BYTES {
        return Outcome::Skipped(Skip::TooLarge);
    }
    let text = match reader(bytes, mime(record)).await {
        Ok(text) => text,
        Err(reason) => {
            let reason = reason.chars().take(120).collect::<String>();
            return if permanent(&reason) { Outcome::Refused(reason) } else { Outcome::Retry(reason) };
        }
    };
    let text = text.trim();
    if text.is_empty() {
        return Outcome::Skipped(Skip::NoText);
    }
    match index::attach_text(store, &record.chat, &record.id, text, index::Source::Ocr).await {
        Ok(true) => Outcome::Attached { chars: record::MAX_TEXT.min(text.chars().count()) as u64, bytes: bytes_len },
        // The record vanished between the download and the attach (a revoke, retention): the text is
        // dropped rather than indexed against nothing.
        Ok(false) => Outcome::Skipped(Skip::NotFound),
        Err(reason) => Outcome::Retry(format!("index:{}", reason.chars().take(120).collect::<String>())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::record::Envelope;
    use futures::executor::block_on;
    use std::cell::Cell;
    use wa_whatsapp_index as seam;
    use whatsapp_rust::waproto::buffa::MessageField;
    use whatsapp_rust::waproto::whatsapp as wap;

    const CHAT: &str = "120363000000000001@g.us";
    const SENDER: &str = "5511999999999@s.whatsapp.net";

    fn envelope(id: &str) -> Envelope {
        Envelope {
            chat: CHAT.into(),
            id: id.into(),
            sender: SENDER.into(),
            sender_alt: String::new(),
            own: false,
            group: true,
            ts: 1_760_000_000_000,
            received: 1_760_000_000_005,
            push_name: "Ana".into(),
        }
    }

    /// One image message, exactly the shape the protocol crate hands `on_message`.
    fn image(id: &str, mime: &str, size: u64) -> Record {
        let message = wap::Message {
            image_message: MessageField::some(wap::message::ImageMessage {
                mimetype: Some(mime.into()),
                caption: Some(String::new()),
                file_length: Some(size),
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
        record::from_message(&envelope(id), &message)
    }

    /// One document message (a scan sent as a file).
    fn document(id: &str, mime: &str, size: u64) -> Record {
        let message = wap::Message {
            document_message: MessageField::some(wap::message::DocumentMessage {
                mimetype: Some(mime.into()),
                file_name: Some("scan.png".into()),
                file_length: Some(size),
                media_key: Some(vec![0x11; 32]),
                direct_path: Some("/v/doc".into()),
                file_sha256: Some(vec![0xab; 32]),
                ..Default::default()
            }),
            ..Default::default()
        };
        record::from_message(&envelope(id), &message)
    }

    fn search(store: &index::Memory, q: &str) -> serde_json::Value {
        let request = seam::Request { op: "search".into(), q: Some(q.into()), ..Default::default() };
        let request = request.validate().expect("a valid search");
        block_on(index::search(store, &request)).expect("the store answers")
    }

    /// A reader that counts how many times it was asked, so "was the worker bothered at all?" is an
    /// assertion and not a guess.
    fn counted<'a>(text: &'a str, calls: &'a Cell<u32>) -> impl FnOnce(Vec<u8>, String) -> std::future::Ready<Result<String, String>> + 'a {
        move |_bytes, _mime| {
            calls.set(calls.get() + 1);
            std::future::ready(Ok(text.to_string()))
        }
    }

    #[test]
    fn an_image_is_ocred_attached_and_found_by_its_text() {
        let store = index::Memory::new();
        let record = image("I1", "image/jpeg", 48_213);
        block_on(index::put(&store, &record)).expect("the image is indexed");
        let calls = Cell::new(0);
        let outcome = block_on(run(&store, &record, vec![0xff, 0xd8, 0xff], counted("SUPERMERCADO CENTRAL 12,90", &calls)));
        assert_eq!(outcome, Outcome::Attached { chars: 26, bytes: 3 });
        assert_eq!(calls.get(), 1, "the reader was asked exactly once");
        // The text is the index record's own `ocr` field, which is what a search reads.
        let stored = block_on(index::load(&store, CHAT, "I1")).unwrap().expect("the record is there");
        assert_eq!(stored.ocr, "SUPERMERCADO CENTRAL 12,90");
        assert_eq!(stored.text, "", "the caption is untouched");
        let answer = search(&store, "supermercado");
        let hits = answer["hits"].as_array().expect("hits");
        assert_eq!(hits.len(), 1, "the photo is findable by what it shows: {answer}");
        assert_eq!(hits[0]["id"], "I1");
        assert_eq!(hits[0]["ocr"], "SUPERMERCADO CENTRAL 12,90");
    }

    #[test]
    fn the_reader_text_is_attached_verbatim_and_bounded_by_the_record_limit() {
        // Parity on the shape of the text: line breaks and accents survive (the worker joins its
        // lines with \n and keeps the script's accents), so a search for an accented word works.
        let store = index::Memory::new();
        let record = image("I2", "image/png", 1_000);
        block_on(index::put(&store, &record)).unwrap();
        let text = "Convênio\nBanco do Brasil\nR$ 1.234,56";
        let calls = Cell::new(0);
        assert!(matches!(block_on(run(&store, &record, vec![1, 2, 3], counted(text, &calls))), Outcome::Attached { .. }));
        let stored = block_on(index::load(&store, CHAT, "I2")).unwrap().unwrap();
        assert_eq!(stored.ocr, text, "the text is not re-wrapped or re-joined by the component");
        assert_eq!(search(&store, "convenio")["hits"].as_array().unwrap().len(), 1, "the accent-folded token index found it");

        // Longer than a record keeps: the attach is bounded at record::MAX_TEXT, exactly as a
        // transcript is, and still searchable by a word near the start.
        let store = index::Memory::new();
        let long = format!("ACOUGUE {} {}", "x".repeat(record::MAX_TEXT + 500), "unreachable");
        let record = image("I3", "image/jpeg", 1_000);
        block_on(index::put(&store, &record)).unwrap();
        let calls = Cell::new(0);
        let outcome = block_on(run(&store, &record, vec![1], counted(&long, &calls)));
        assert_eq!(outcome, Outcome::Attached { chars: record::MAX_TEXT as u64, bytes: 1 });
        let stored = block_on(index::load(&store, CHAT, "I3")).unwrap().unwrap();
        assert_eq!(stored.ocr.chars().count(), record::MAX_TEXT);
        assert_eq!(search(&store, "acougue")["hits"].as_array().unwrap().len(), 1);
        assert_eq!(search(&store, "unreachable")["hits"].as_array().unwrap().len(), 0, "what fell outside the bound is not searchable");
    }

    #[test]
    fn an_oversized_image_is_refused_cleanly_and_the_reader_is_never_started() {
        let store = index::Memory::new();
        let record = image("BIG", "image/jpeg", MAX_IMAGE_BYTES + 1);
        block_on(index::put(&store, &record)).unwrap();
        assert_eq!(wanted(&record), Err(Skip::TooLarge), "the record's own size is enough to refuse it");
        let calls = Cell::new(0);
        let outcome = block_on(run(&store, &record, vec![0u8; 16], counted("never", &calls)));
        assert_eq!(outcome, Outcome::Skipped(Skip::TooLarge));
        assert_eq!(calls.get(), 0, "the reader was not started for a refused image");
        assert_eq!(outcome.word(), "image_too_large");

        // And a record that lied about its size cannot get a bigger blob read either.
        let lying = image("LIE", "image/jpeg", 1_000);
        block_on(index::put(&store, &lying)).unwrap();
        let calls = Cell::new(0);
        let big = vec![0u8; MAX_IMAGE_BYTES as usize + 1];
        assert_eq!(block_on(run(&store, &lying, big, counted("never", &calls))), Outcome::Skipped(Skip::TooLarge));
        assert_eq!(calls.get(), 0);
    }

    #[test]
    fn only_images_and_image_documents_are_read() {
        let text_message = record::from_message(&envelope("T1"), &wap::Message { conversation: Some("oi".into()), ..Default::default() });
        assert_eq!(wanted(&text_message), Err(Skip::NotAnImage));
        let pdf = document("D1", "application/pdf", 10_000);
        assert_eq!(wanted(&pdf), Err(Skip::NotAnImage), "a PDF needs a text extractor, not OCR");
        let scan = document("D2", "image/png", 10_000);
        assert_eq!(wanted(&scan), Ok(()), "a scan sent as a document is a screenshot with a filename");
    }

    #[test]
    fn a_view_once_or_keyless_image_is_not_downloadable_and_is_not_read() {
        let mut record = image("V1", "image/jpeg", 1_000);
        if let Some(media) = record.media.as_mut() {
            media.downloadable = false;
            media.media_key.clear();
        }
        assert_eq!(wanted(&record), Err(Skip::NotDownloadable));
        record.media = None;
        assert_eq!(wanted(&record), Err(Skip::NoMedia));
    }

    #[test]
    fn a_revoked_or_already_read_image_is_skipped() {
        let store = index::Memory::new();
        let mut revoked = image("R1", "image/jpeg", 1_000);
        revoked.deleted = true;
        assert_eq!(wanted(&revoked), Err(Skip::Deleted));

        let record = image("I4", "image/jpeg", 1_000);
        block_on(index::put(&store, &record)).unwrap();
        assert!(block_on(index::attach_text(&store, CHAT, "I4", "primeira leitura", index::Source::Ocr)).unwrap());
        let stored = block_on(index::load(&store, CHAT, "I4")).unwrap().unwrap();
        assert_eq!(wanted(&stored), Err(Skip::AlreadyRead));
        let calls = Cell::new(0);
        assert_eq!(block_on(run(&store, &stored, vec![1], counted("segunda", &calls))), Outcome::Skipped(Skip::AlreadyRead));
        assert_eq!(calls.get(), 0);
        let stored = block_on(index::load(&store, CHAT, "I4")).unwrap().unwrap();
        assert_eq!(stored.ocr, "primeira leitura", "a second pass never overwrites the first");
    }

    #[test]
    fn no_text_is_not_attached_and_an_empty_reader_answer_is_not_an_empty_record() {
        let store = index::Memory::new();
        let record = image("N1", "image/jpeg", 1_000);
        block_on(index::put(&store, &record)).unwrap();
        let calls = Cell::new(0);
        assert_eq!(block_on(run(&store, &record, vec![1], counted("   \n ", &calls))), Outcome::Skipped(Skip::NoText));
        let stored = block_on(index::load(&store, CHAT, "N1")).unwrap().unwrap();
        assert_eq!(stored.ocr, "", "an empty reading is not text");
        // The reader's own word travels as a permanent refusal.
        let refused: fn(Vec<u8>, String) -> std::future::Ready<Result<String, String>> =
            |_b, _m| std::future::ready(Err("no_text_detected".to_string()));
        assert_eq!(block_on(run(&store, &record, vec![1], refused)), Outcome::Refused("no_text_detected".into()));
    }

    #[test]
    fn permanent_answers_stay_permanent_and_transient_ones_are_retried() {
        for word in ["no_text_detected", "image_too_large", "unsupported_media:application/pdf", "ocr_text_too_long", "offline_model_unavailable", "ocr_python_missing"] {
            assert!(permanent(word), "{word}");
        }
        for word in ["worker_stalled", "worker_timeout", "worker_eof", "busy", "download:temporarily unavailable"] {
            assert!(!permanent(word), "{word}");
        }
        let store = index::Memory::new();
        let record = image("T2", "image/jpeg", 1_000);
        block_on(index::put(&store, &record)).unwrap();
        let stalled: fn(Vec<u8>, String) -> std::future::Ready<Result<String, String>> =
            |_b, _m| std::future::ready(Err("worker_stalled".to_string()));
        let outcome = block_on(run(&store, &record, vec![1], stalled));
        assert_eq!(outcome, Outcome::Retry("worker_stalled".into()));
        assert!(outcome.retry());
        assert_eq!(outcome.reason(), Some("worker_stalled"));
    }

    #[test]
    fn the_media_type_handed_to_the_reader_is_the_record_s_own() {
        assert_eq!(mime(&image("M1", "image/webp", 10)), "image/webp");
        let mut bare = image("M2", "", 10);
        if let Some(media) = bare.media.as_mut() {
            media.mime.clear();
        }
        assert_eq!(mime(&bare), "image/jpeg", "WhatsApp images are JPEG unless they say otherwise");
        assert!(is_image_mime("image/png"));
        assert!(is_image_mime("IMAGE/JPEG; q=1"));
        assert!(!is_image_mime("application/pdf"));
    }

    #[test]
    fn the_backlog_lists_images_without_ocr_text_and_stops_at_its_budget() {
        let store = index::Memory::new();
        for id in ["B1", "B2", "B3"] {
            block_on(index::put(&store, &image(id, "image/jpeg", 1_000))).unwrap();
        }
        // One already read, one PDF document, one image document (a scan).
        assert!(block_on(index::attach_text(&store, CHAT, "B1", "já lida", index::Source::Ocr)).unwrap());
        block_on(index::put(&store, &document("B4", "application/pdf", 1_000))).unwrap();
        block_on(index::put(&store, &document("B5", "image/png", 1_000))).unwrap();

        let backlog = block_on(index::ocr_backlog(&store, 10)).expect("the index answers");
        let ids: Vec<&str> = backlog.iter().map(|(_, id)| id.as_str()).collect();
        assert!(ids.contains(&"B2") && ids.contains(&"B3"), "{ids:?}");
        assert!(ids.contains(&"B5"), "the scan sent as a document is in the backlog: {ids:?}");
        assert!(!ids.contains(&"B1"), "an image already read is not queued again: {ids:?}");
        assert!(!ids.contains(&"B4"), "a PDF is not an image: {ids:?}");
        // A "no text" answer is remembered, so the pass does not re-download the same screenshot.
        block_on(index::mark_unreadable(&store, CHAT, "B2", "no_text_detected")).unwrap();
        let backlog = block_on(index::ocr_backlog(&store, 10)).unwrap();
        assert!(!backlog.iter().any(|(_, id)| id == "B2"), "an image already answered `no text` is not queued again");
        assert_eq!(block_on(index::unreadable(&store, CHAT, "B2")).unwrap().as_deref(), Some("no_text_detected"));
        assert_eq!(block_on(index::unreadable(&store, CHAT, "B3")).unwrap(), None);
        // And the budget is a budget: one record per pass is what keeps the pass bounded.
        assert_eq!(block_on(index::ocr_backlog(&store, 1)).unwrap().len(), 1);
    }
}
