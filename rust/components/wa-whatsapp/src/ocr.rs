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
//! * **No text in any log line, and no identity either.** Callers log counts, a state word and the
//!   chat/id as `sha256:<32 hex>` digests ([`line`], `crate::privacy`); the text goes to
//!   [`index::attach_text`] and nowhere else. The reader's own refusals (`no_text_detected`, …) are
//!   words, not content.
//! * **A permanent answer stays permanent, and it is remembered.** A screenshot with no words, a media
//!   type that is not an image, and an unprovisioned worker are all answers: retrying them
//!   re-downloads a photo to learn the same thing. [`settle`] writes the word under
//!   `ix/ocr/<chat>/<id>`, so the backlog pass (`index::ocr_backlog`) skips the image from then on. A
//!   stalled or restarted worker is different: it is retried with an exponential backoff, and only
//!   [`MAX_ATTEMPTS`] times.
//!
//! Everything here is pure or store-only (no host call and no wasm target requirement), so a native
//! test drives the identical code with a fake reader and `index::Memory`; the guest supplies the
//! reader (`vision::read`) and the bytes (`client.download_from_params`) as arguments.

use crate::index::{self, Store};
use crate::privacy;
use crate::record::{self, Record};

/// Largest image this component will OCR, the old bridge's bound (`record::MAX_MEDIA_BYTES` is the
/// same number: what the pipeline may download at all is what it may read).
pub const MAX_IMAGE_BYTES: u64 = record::MAX_MEDIA_BYTES;

/// How long the lane waits after the first transient failure, and the ceiling the doubling stops at.
/// The backlog refill (`index_ocr_every_seconds`, 60 s by default) is what re-queues a retry, so the
/// base wait is one pass: an image whose worker was restarting is tried on the next pass, not on every
/// tick in between.
pub const RETRY_BASE_MS: i64 = 60_000;
pub const RETRY_CAP_MS: i64 = 30 * 60_000;
/// Attempts one image gets, the first included. After [`MAX_ATTEMPTS`] the mark says
/// `retry_exhausted:<word>` and nothing downloads the image again: the cap is what stops a worker that
/// never recovers from becoming an image that is re-read forever.
pub const MAX_ATTEMPTS: u32 = 5;
/// Longest reason word kept in the marker and in a log line.
pub const MAX_REASON: usize = 48;

/// The wait before attempt `attempts + 1`: doubling from [`RETRY_BASE_MS`], capped at [`RETRY_CAP_MS`].
pub fn backoff_ms(attempts: u32) -> i64 {
    let shift = attempts.saturating_sub(1).min(16);
    RETRY_BASE_MS.saturating_mul(1i64 << shift).min(RETRY_CAP_MS)
}

/// The reason a marker and a log line keep: one bounded token, never text. A worker's reason can be a
/// sentence (an I/O error with a path in it), so everything outside the token alphabet is dropped, a
/// run of eight or more digits (a phone number, a token) is redacted, and a long reason is cut. Empty
/// becomes `unknown`, so a field is never blank.
pub fn word(reason: &str) -> String {
    let fated: String = reason
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.' | ':'))
        .collect();
    let mut out = String::with_capacity(fated.len().min(MAX_REASON));
    let mut digits = 0usize;
    for ch in fated.chars() {
        if ch.is_ascii_digit() {
            digits += 1;
            if digits <= 7 {
                out.push(ch);
            } else if digits == 8 {
                // An identifier, not a word: keep the shape, drop the value.
                let keep = out.len().saturating_sub(7);
                out.truncate(keep);
                out.push('n');
            }
            continue;
        }
        digits = 0;
        out.push(ch);
    }
    if out.is_empty() {
        return "unknown".to_string();
    }
    out.chars().take(MAX_REASON).collect()
}

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
    /// An earlier attempt failed in a way another attempt could change, and the backoff has not
    /// passed yet (`index::OcrMark::Retry`, `settle`).
    RetryScheduled,
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
            Skip::RetryScheduled => "retry_scheduled",
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
        // Nothing arrived where an image was promised: a truncated download or a cache answering
        // empty. Another attempt can differ, so it is a retry (bounded by `MAX_ATTEMPTS`), not a mark
        // that would retire the image forever.
        return Outcome::Retry("empty_image".into());
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

/// Is a mark on this image a reason not to read it at `now_ms`? `Some(skip)` when the lane must pass
/// it over, `None` when it may read (no mark, or a retry whose backoff has passed).
pub fn skip_of(mark: &index::OcrMark, now_ms: i64) -> Option<Skip> {
    if !mark.blocks(now_ms) {
        return None;
    }
    Some(match mark {
        index::OcrMark::Terminal { .. } => Skip::Unreadable,
        index::OcrMark::Retry { .. } => Skip::RetryScheduled,
    })
}

/// What the lane does with one attempt's outcome: remember it in the index and say when the next
/// attempt is due.
///
/// This is the whole loop's decision, kept here (and not in the guest) so a native test can drive it:
/// `run` -> `settle` -> `index::ocr_backlog` is a pass, and a bug that re-downloads the same image
/// every pass shows up as a worker call count in `cargo test`.
///
/// * attached: nothing to remember, and a stale retry mark is cleared;
/// * a terminal answer (`no_text_detected`, `image_too_large`, the reader refused the media) or the
///   reader's permanent refusal: a [`index::OcrMark::Terminal`] with the word, forever;
/// * a transient failure (a stalled/crashed worker, a full queue, a download that timed out): a
///   [`index::OcrMark::Retry`] with the attempt count and `now + backoff`, or - once [`MAX_ATTEMPTS`]
///   attempts have failed - a terminal `retry_exhausted:<word>`;
/// * a record-level skip (not an image, revoked, no media keys): nothing, because the next pass
///   re-filters it for free and a mark would be state for a decision the record already carries.
///
/// Returns `Some(next_ms)` when another attempt was scheduled, `None` when the image is settled. A
/// store failure is returned, never swallowed: a mark that was not written is the loop coming back.
pub async fn settle<S: Store>(store: &S, chat: &str, id: &str, outcome: &Outcome, now_ms: i64) -> Result<Option<i64>, String> {
    let attempts = match index::ocr_mark(store, chat, id).await? {
        Some(index::OcrMark::Retry { attempts, .. }) => attempts,
        _ => 0,
    };
    let mark = match outcome {
        Outcome::Attached { .. } => {
            index::clear_ocr_mark(store, chat, id).await?;
            return Ok(None);
        }
        Outcome::Skipped(skip) => match skip {
            // The image itself answered: a screenshot with no words, a photograph over the bound.
            Skip::NoText | Skip::TooLarge => index::OcrMark::Terminal { reason: skip.word().to_string() },
            // Already remembered, or a property of the record (`deleted`, `no_media`, …) the next pass
            // re-filters without a download.
            _ => return Ok(None),
        },
        // `run` only produces `Refused` for an answer it classified as permanent.
        Outcome::Refused(reason) => index::OcrMark::Terminal { reason: word(reason) },
        Outcome::Retry(reason) => {
            let attempts = attempts.saturating_add(1);
            if attempts >= MAX_ATTEMPTS {
                index::OcrMark::Terminal { reason: word(&format!("retry_exhausted:{}", word(reason))) }
            } else {
                let next_ms = now_ms.saturating_add(backoff_ms(attempts));
                index::mark_ocr(store, chat, id, &index::OcrMark::Retry { reason: word(reason), attempts, next_ms }).await?;
                return Ok(Some(next_ms));
            }
        }
    };
    index::mark_ocr(store, chat, id, &mark).await?;
    Ok(None)
}

/// The one line the lane prints for one attempt: a state word, counts, and the chat/id as digests.
/// Built here rather than at the call site for two reasons: a native test scans every line the lane can
/// print (`tests::no_line_the_lane_prints_carries_a_chat_or_a_message_id`), and a reason can never
/// become a paragraph, because [`word`] bounds it.
pub fn line(outcome: &Outcome, chat: &str, id: &str, download_ms: i64) -> String {
    let at = privacy::at(chat, id);
    match outcome {
        Outcome::Attached { chars, bytes } => format!("ocr ready {at} chars={chars} bytes={bytes} download_ms={download_ms}"),
        Outcome::Skipped(skip) => format!("ocr skipped {at} reason={}", skip.word()),
        Outcome::Refused(reason) => format!("ocr refused {at} reason={}", word(reason)),
        Outcome::Retry(reason) => format!("ocr retry {at} reason={}", word(reason)),
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

        let backlog = block_on(index::ocr_backlog(&store, 10, 0)).expect("the index answers");
        let ids: Vec<&str> = backlog.iter().map(|(_, id)| id.as_str()).collect();
        assert!(ids.contains(&"B2") && ids.contains(&"B3"), "{ids:?}");
        assert!(ids.contains(&"B5"), "the scan sent as a document is in the backlog: {ids:?}");
        assert!(!ids.contains(&"B1"), "an image already read is not queued again: {ids:?}");
        assert!(!ids.contains(&"B4"), "a PDF is not an image: {ids:?}");
        // A "no text" answer is remembered, so the pass does not re-download the same screenshot.
        block_on(index::mark_unreadable(&store, CHAT, "B2", "no_text_detected")).unwrap();
        let backlog = block_on(index::ocr_backlog(&store, 10, 0)).unwrap();
        assert!(!backlog.iter().any(|(_, id)| id == "B2"), "an image already answered `no text` is not queued again");
        assert_eq!(block_on(index::unreadable(&store, CHAT, "B2")).unwrap().as_deref(), Some("no_text_detected"));
        assert_eq!(block_on(index::unreadable(&store, CHAT, "B3")).unwrap(), None);
        // And the budget is a budget: one record per pass is what keeps the pass bounded.
        assert_eq!(block_on(index::ocr_backlog(&store, 1, 0)).unwrap().len(), 1);
    }

    /// One attempt's answer, as the fake worker gives it.
    type Answer = Result<String, String>;

    /// One pass of the lane, exactly as the guest runs it: the backlog (`index::ocr_backlog`), the
    /// real `run` and the real `settle` for each image it lists. `calls` counts worker calls, so "was
    /// the worker bothered again?" is an assertion and not a guess. Returns how many images the pass
    /// attempted.
    fn pass(store: &index::Memory, now_ms: i64, answer: &Answer, calls: &Cell<u32>) -> usize {
        let mut tried = 0;
        for (chat, id) in block_on(index::ocr_backlog(store, 8, now_ms)).expect("the index answers") {
            let Some(record) = block_on(index::load(store, &chat, &id)).unwrap() else { continue };
            let outcome = block_on(run(store, &record, vec![0xff, 0xd8, 0xff], |_bytes, _mime| {
                calls.set(calls.get() + 1);
                std::future::ready(answer.clone())
            }));
            block_on(settle(store, &chat, &id, &outcome, now_ms)).expect("the mark is written");
            tried += 1;
        }
        tried
    }

    #[test]
    fn a_picture_with_nothing_to_read_is_read_once_and_the_next_pass_skips_it() {
        // The live bug (08/11): `no_text_detected` is the reader's answer, and it is an error word, so
        // it came back as a refusal that nothing remembered - the backlog re-downloaded and re-read
        // the same eight screenshots every minute. A fixture image with no text is read once, the
        // marker carries the reason, and every later pass leaves the worker alone.
        let store = index::Memory::new();
        for id in ["N1", "N2", "N3"] {
            block_on(index::put(&store, &image(id, "image/jpeg", 1_000))).unwrap();
        }
        let calls = Cell::new(0);
        let no_text: Answer = Err("no_text_detected".into());
        assert_eq!(pass(&store, 0, &no_text, &calls), 3, "the first pass reads every unread image");
        assert_eq!(calls.get(), 3, "one worker call per image, no more");

        // The reason is in the marker, as a word.
        assert_eq!(block_on(index::unreadable(&store, CHAT, "N1")).unwrap().as_deref(), Some("no_text_detected"));
        let mark = block_on(index::ocr_mark(&store, CHAT, "N1")).unwrap().expect("a mark");
        assert_eq!(mark, index::OcrMark::Terminal { reason: "no_text_detected".into() });
        assert!(mark.blocks(0) && mark.blocks(i64::MAX), "a terminal mark blocks every later pass");

        // Every later pass - a minute, an hour, a restart - finds nothing to do and calls no worker.
        for now in [60_000, 120_000, 3_600_000, i64::MAX] {
            assert_eq!(pass(&store, now, &no_text, &calls), 0, "nothing is queued at t={now}");
        }
        assert_eq!(calls.get(), 3, "the worker was not bothered again: {calls:?}");

        // An oversized image and an empty reading are answered the same way (`Skipped`), not retried.
        let store = index::Memory::new();
        block_on(index::put(&store, &image("BIG", "image/jpeg", MAX_IMAGE_BYTES + 1))).unwrap();
        block_on(index::put(&store, &image("EMPTY", "image/jpeg", 10))).unwrap();
        let calls = Cell::new(0);
        assert_eq!(pass(&store, 0, &Ok("   \n ".into()), &calls), 2, "the oversized image is settled from its record, the empty reading is fetched");
        assert_eq!(calls.get(), 1, "only the readable-size image cost a worker call");
        assert_eq!(block_on(index::unreadable(&store, CHAT, "BIG")).unwrap().as_deref(), Some("image_too_large"));
        assert_eq!(pass(&store, 600_000, &Ok("texto".into()), &calls), 0, "both are settled at t=600 s");
        assert_eq!(calls.get(), 1);
        assert_eq!(block_on(index::unreadable(&store, CHAT, "EMPTY")).unwrap().as_deref(), Some("no_text_detected"));
    }

    #[test]
    fn a_transient_failure_is_retried_with_an_exponential_backoff_and_stops_at_the_cap() {
        let store = index::Memory::new();
        block_on(index::put(&store, &image("T1", "image/jpeg", 1_000))).unwrap();
        let calls = Cell::new(0);
        let stalled: Answer = Err("worker_stalled".into());

        // Attempt 1 at t=0: a retry is scheduled one base wait later, and not before.
        assert_eq!(pass(&store, 0, &stalled, &calls), 1);
        assert_eq!(block_on(index::unreadable(&store, CHAT, "T1")).unwrap(), None, "a pending retry is not a terminal answer");
        assert_eq!(
            block_on(index::ocr_mark(&store, CHAT, "T1")).unwrap(),
            Some(index::OcrMark::Retry { reason: "worker_stalled".into(), attempts: 1, next_ms: RETRY_BASE_MS })
        );
        assert_eq!(pass(&store, RETRY_BASE_MS - 1, &stalled, &calls), 0, "the backoff has not passed");
        assert_eq!(calls.get(), 1, "no worker was called during the backoff");

        // Attempt 2 at t=60 s: the wait doubles. Then 3 and 4, still inside the cap.
        assert_eq!(pass(&store, RETRY_BASE_MS, &stalled, &calls), 1);
        assert_eq!(calls.get(), 2);
        let second = RETRY_BASE_MS + backoff_ms(2);
        assert_eq!(backoff_ms(2), 2 * RETRY_BASE_MS, "the wait doubles");
        assert_eq!(pass(&store, second, &stalled, &calls), 1);
        assert_eq!(pass(&store, second + backoff_ms(3), &stalled, &calls), 1);
        assert_eq!(calls.get(), 4);
        let mark = block_on(index::ocr_mark(&store, CHAT, "T1")).unwrap().unwrap();
        assert_eq!(mark.reason(), "worker_stalled");
        assert!(matches!(mark, index::OcrMark::Retry { attempts: 4, .. }), "{mark:?}");

        // Attempt 5 is the last one: the cap turns the failure into a terminal mark.
        let last = second + backoff_ms(3) + backoff_ms(4);
        assert_eq!(pass(&store, last, &stalled, &calls), 1);
        assert_eq!(calls.get(), MAX_ATTEMPTS);
        assert_eq!(
            block_on(index::ocr_mark(&store, CHAT, "T1")).unwrap(),
            Some(index::OcrMark::Terminal { reason: "retry_exhausted:worker_stalled".into() })
        );
        // And then never again, at any time.
        for now in [last + 1, last + 86_400_000, i64::MAX] {
            assert_eq!(pass(&store, now, &stalled, &calls), 0, "no attempt after the cap (t={now})");
        }
        assert_eq!(calls.get(), MAX_ATTEMPTS, "exactly the cap of worker calls");

        // The backoff is capped as well: an attempt count beyond the cap cannot overflow or wait
        // longer than RETRY_CAP_MS.
        assert_eq!(backoff_ms(1), RETRY_BASE_MS);
        assert_eq!(backoff_ms(3), 4 * RETRY_BASE_MS);
        assert_eq!(backoff_ms(20), RETRY_CAP_MS);
        assert_eq!(backoff_ms(u32::MAX), RETRY_CAP_MS);
    }

    #[test]
    fn a_retry_that_succeeds_attaches_the_text_and_clears_the_mark() {
        let store = index::Memory::new();
        block_on(index::put(&store, &image("T2", "image/jpeg", 1_000))).unwrap();
        let calls = Cell::new(0);
        assert_eq!(pass(&store, 0, &Err("busy".into()), &calls), 1);
        assert!(block_on(index::ocr_mark(&store, CHAT, "T2")).unwrap().is_some());
        assert_eq!(pass(&store, RETRY_BASE_MS, &Ok("MERCADO 12,90".into()), &calls), 1);
        assert_eq!(calls.get(), 2);
        let stored = block_on(index::load(&store, CHAT, "T2")).unwrap().unwrap();
        assert_eq!(stored.ocr, "MERCADO 12,90");
        assert_eq!(block_on(index::ocr_mark(&store, CHAT, "T2")).unwrap(), None, "the retry mark is gone once the image is read");
        assert_eq!(pass(&store, 10 * RETRY_BASE_MS, &Ok("x".into()), &calls), 0, "an image with text is not read again");
    }

    #[test]
    fn no_line_the_lane_prints_carries_a_chat_or_a_message_id() {
        let store = index::Memory::new();
        let record = image("3EB0A1B2C3D4E5F6", "image/jpeg", 1_000);
        block_on(index::put(&store, &record)).unwrap();
        let calls = Cell::new(0);
        let attached = block_on(run(&store, &record, vec![1, 2, 3], counted("MERCADO", &calls)));
        // The reader's real refusal on a fresh image, so the `refused` line is the one `run` produces.
        let store2 = index::Memory::new();
        let other = image("3EB0A1B2C3D4E5F7", "image/jpeg", 1_000);
        block_on(index::put(&store2, &other)).unwrap();
        let refused: fn(Vec<u8>, String) -> std::future::Ready<Result<String, String>> =
            |_b, _m| std::future::ready(Err("no_text_detected".to_string()));
        let mut outcomes = vec![
            attached,
            Outcome::Skipped(Skip::TooLarge),
            Outcome::Skipped(Skip::NoText),
            block_on(run(&store2, &other, vec![1], refused)),
            Outcome::Retry("worker_stalled".into()),
        ];
        // A reason that tried to smuggle a JID and a newline into the line is a token too.
        outcomes.push(Outcome::Retry("download:5511999999999@s.whatsapp.net\nsecond line".into()));
        for outcome in &outcomes {
            let line = line(outcome, CHAT, "3EB0A1B2C3D4E5F6", 42);
            // `ocr <state> …`: the state word is the first thing an operator greps for.
            let state = line.split(' ').nth(1).expect("a state word");
            assert!(matches!(state, "ready" | "skipped" | "refused" | "retry"), "{line}");
            assert!(line.starts_with(&format!("ocr {state} chat=sha256:")), "the line names the fields second: {line}");
            assert!(line.contains(&format!("chat={}", crate::privacy::mark(CHAT))), "the chat is a mark: {line}");
            assert!(line.contains("id=sha256:"), "the id is a mark: {line}");
            assert!(!line.contains('@'), "no JID: {line}");
            assert!(!line.contains("5511999999999"), "no phone number: {line}");
            assert!(!line.contains("3EB0A1B2C3D4E5F6"), "no message id: {line}");
            assert!(!line.contains('\n') && line.split(' ').all(|field| !field.is_empty()), "one line of fields: {line}");
        }
    }

    #[test]
    fn a_reason_word_is_bounded_and_never_carries_a_space() {
        assert_eq!(word("no_text_detected"), "no_text_detected");
        assert_eq!(word("download:temporarily unavailable"), "download:temporarilyunavailable");
        assert_eq!(word("a\nb\tc"), "abc");
        assert_eq!(word(""), "unknown");
        assert_eq!(word("x").len(), 1);
        assert_eq!(word(&"y".repeat(500)).len(), MAX_REASON);
        // A path or a phone number cannot survive as a field: no space, no '@', no '+', bounded.
        let word_of = word("/home/ubuntu/ocr/5511999999999@s.whatsapp.net");
        assert!(!word_of.contains('@') && !word_of.contains('/') && word_of.len() <= MAX_REASON, "{word_of}");
        assert!(!word_of.contains("5511999999999"), "a long digit run is redacted: {word_of}");
    }
}
