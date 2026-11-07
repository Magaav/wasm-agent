//! Building the bytes SMTP carries: one validated request, as an RFC 5322 message.
//!
//! Everything here reads from [`wa_email_outbox::Verified`], the type only a validated request
//! produces - every address is a [`Mailbox`], every subject is one line, every bound has been checked -
//! so a header cannot be built from unvalidated text. That is why composition lives outside the
//! outbox crate but takes its type: the seam stays free of MIME, and this module cannot be handed raw
//! request fields.
//!
//! The body is base64 (`Content-Transfer-Encoding: base64`), so a message is 7-bit clean and needs no
//! SMTPUTF8/8BITMIME negotiation; attachments are a `multipart/mixed` second part each, with their
//! own base64 body.
use base64::Engine as _;
use sha2::{Digest, Sha256};
use wa_email_outbox::{Mailbox, Verified};

/// Longest line we emit, header folding included (RFC 5322's hard limit is 998).
const MAX_LINE: usize = 78;
/// Longest body line of base64 (a multiple of 4).
const BODY_LINE: usize = 76;

/// One composed message: the bytes to send and the id the server will see.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Composed {
    pub bytes: Vec<u8>,
    pub message_id: String,
    /// How many addresses the message is delivered to (`to` + `cc`, deduplicated).
    pub recipients: usize,
}

/// Compose one message. `dedupe_key` seeds the message id, so the same request re-sent after a retry
/// carries the same id and a receiving server can recognise the duplicate.
pub fn compose(from: &Mailbox, verified: &Verified, dedupe_key: &str, now_ms: i64) -> Composed {
    let message_id = format!("<{}@{}>", digest(&format!("{dedupe_key}|{now_ms}"), 24), from.domain);
    let mut headers = String::new();
    push_header(&mut headers, "From", &from.header());
    push_header(&mut headers, "To", &address_list(&verified.to));
    if !verified.cc.is_empty() {
        push_header(&mut headers, "Cc", &address_list(&verified.cc));
    }
    push_header(&mut headers, "Subject", &encode_words(&verified.subject));
    push_header(&mut headers, "Date", &format_date(now_ms));
    push_header(&mut headers, "Message-ID", &message_id);
    if let Some(reply_to) = verified.in_reply_to.as_deref() {
        push_header(&mut headers, "In-Reply-To", reply_to);
        push_header(&mut headers, "References", reply_to);
    }
    push_header(&mut headers, "MIME-Version", "1.0");
    let body: Vec<u8> = if verified.attachments.is_empty() {
        push_header(&mut headers, "Content-Type", "text/plain; charset=utf-8");
        push_header(&mut headers, "Content-Transfer-Encoding", "base64");
        let mut body = String::new();
        body.push_str(&wrap_base64(&encode_base64(verified.body.as_bytes())));
        body.into_bytes()
    } else {
        let boundary = format!("=_wa_email_{}", digest(dedupe_key, 16));
        push_header(&mut headers, "Content-Type", &format!("multipart/mixed; boundary=\"{boundary}\""));
        let mut body = String::new();
        body.push_str(&format!("--{boundary}\r\n"));
        body.push_str("Content-Type: text/plain; charset=utf-8\r\n");
        body.push_str("Content-Transfer-Encoding: base64\r\n\r\n");
        body.push_str(&wrap_base64(&encode_base64(verified.body.as_bytes())));
        body.push_str("\r\n");
        for (index, attachment) in verified.attachments.iter().enumerate() {
            body.push_str(&format!("--{boundary}\r\n"));
            body.push_str(&format!("Content-Type: {}\r\n", attachment.mime));
            body.push_str(&format!("Content-Disposition: attachment; filename=\"{}\"\r\n", encode_words(&attachment.filename)));
            body.push_str("Content-Transfer-Encoding: base64\r\n\r\n");
            body.push_str(&wrap_base64(&encode_base64(&attachment.bytes)));
            body.push_str("\r\n");
            let _ = index;
        }
        body.push_str(&format!("--{boundary}--\r\n"));
        body.into_bytes()
    };
    let mut bytes = Vec::with_capacity(headers.len() + body.len());
    bytes.extend_from_slice(headers.as_bytes());
    bytes.extend_from_slice(b"\r\n");
    bytes.extend_from_slice(&body);
    Composed { bytes, message_id, recipients: verified.recipients().len() }
}

fn address_list(list: &[Mailbox]) -> String {
    list.iter().map(Mailbox::header).collect::<Vec<_>>().join(", ")
}

/// One header line, folded at [`MAX_LINE`] on its spaces, CRLF-terminated.
fn push_header(out: &mut String, name: &str, value: &str) {
    let mut line = format!("{name}: {value}");
    while line.chars().count() > MAX_LINE {
        // Fold on the last space that fits, so a long address list wraps the way a mail client's does.
        let cut = match line.char_indices().take(MAX_LINE).filter(|(_, c)| *c == ' ').last() {
            Some((at, _)) => at,
            None => line.char_indices().take(MAX_LINE).last().map(|(at, _)| at).unwrap_or(0),
        };
        if cut == 0 {
            break;
        }
        out.push_str(&line[..cut]);
        out.push_str("\r\n");
        line = format!(" {}", line[cut..].trim_start());
        if !line.starts_with(' ') {
            line.insert(0, ' ');
        }
    }
    out.push_str(line.trim_end());
    out.push_str("\r\n");
}

/// RFC 2047 encode a header value when it is not plain ASCII (a subject, a filename). ASCII values are
/// left exactly as the operator wrote them.
pub fn encode_words(value: &str) -> String {
    if value.is_ascii() {
        return value.to_string();
    }
    format!("=?UTF-8?B?{}?=", encode_base64(value.as_bytes()))
}

fn encode_base64(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

/// Wrap base64 at [`BODY_LINE`] with CRLF, trailing CRLF included.
fn wrap_base64(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + text.len() / BODY_LINE * 2 + 2);
    let bytes = text.as_bytes();
    let mut index = 0usize;
    while index < bytes.len() {
        let end = (index + BODY_LINE).min(bytes.len());
        out.push_str(&text[index..end]);
        out.push_str("\r\n");
        index = end;
    }
    if out.is_empty() {
        out.push_str("\r\n");
    }
    out
}

/// A `Date:` value in UTC: `Wed, 06 Nov 2026 10:00:00 +0000`.
pub fn format_date(now_ms: i64) -> String {
    let seconds = now_ms.div_euclid(1_000);
    let days = seconds.div_euclid(86_400);
    let time_of_day = seconds.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    let weekday = ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"][days.rem_euclid(7) as usize];
    let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    format!(
        "{weekday}, {day:02} {} {year:04} {:02}:{:02}:{:02} +0000",
        months[(month - 1) as usize],
        time_of_day / 3_600,
        (time_of_day % 3_600) / 60,
        time_of_day % 60
    )
}

/// Howard Hinnant's `civil_from_days`: the inverse of the date formula in `mime`.
fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let day_of_era = z - era * 146_097;
    let year_of_era = (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let year = year_of_era + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let mp = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    (if month <= 2 { year + 1 } else { year }, month, day)
}

fn digest(text: &str, hex_chars: usize) -> String {
    let digest = Sha256::digest(text.as_bytes());
    let mut out = String::with_capacity(64);
    for byte in digest {
        out.push_str(&format!("{byte:02x}"));
    }
    out.truncate(hex_chars);
    out
}

/// The decoded body of a composed message, for a test or a fake server that wants to read it back.
#[cfg(test)]
fn decoded_bodies(bytes: &[u8]) -> Vec<Vec<u8>> {
    let text = String::from_utf8_lossy(bytes).to_string();
    let (_, body) = text.split_once("\r\n\r\n").unwrap_or(("", &text));
    let mut out = Vec::new();
    let mut current = String::new();
    for line in body.split("\r\n") {
        if line.starts_with("Content-Transfer-Encoding: base64") {
            continue;
        }
        if line.contains("Content-Type:") || line.starts_with("Content-Disposition:") || line.starts_with("--=") {
            if !current.trim().is_empty() {
                out.push(base64::engine::general_purpose::STANDARD.decode(current.trim()).unwrap_or_default());
                current.clear();
            }
            continue;
        }
        current.push_str(line);
    }
    if !current.trim().is_empty() {
        out.push(base64::engine::general_purpose::STANDARD.decode(current.trim()).unwrap_or_default());
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use wa_email_outbox::{Attachment, Request};

    fn verified(to: &[&str], cc: &[&str], subject: &str, body: &str) -> Verified {
        let request = Request {
            to: to.iter().map(|value| value.to_string()).collect(),
            cc: cc.iter().map(|value| value.to_string()).collect(),
            subject: subject.into(),
            body: body.into(),
            in_reply_to: None,
            attachments: Vec::new(),
        };
        request.validate().expect("a valid request")
    }

    #[test]
    fn a_plain_message_carries_the_headers_mail_needs_and_a_base64_body() {
        let from = Mailbox::parse("me@example.com").unwrap();
        let verified = verified(&["ana@example.com"], &[], "Relatório mensal", "Segue o relatório.\n\nObrigada.");
        let composed = compose(&from, &verified, "dedupe", 1_793_959_200_000);
        let text = String::from_utf8(composed.bytes.clone()).unwrap();
        assert!(text.starts_with("From: <me@example.com>\r\n"), "{text}");
        assert!(text.contains("\r\nTo: <ana@example.com>\r\n"));
        assert!(text.contains("Subject: =?UTF-8?B?"), "a non-ASCII subject is encoded, not sent raw");
        assert!(text.contains("\r\nMessage-ID: <"));
        assert!(text.contains("\r\nDate: Fri, 06 Nov 2026 10:00:00 +0000\r\n"), "the date is the header shape mail expects: {text}");
        assert!(text.contains("\r\nMIME-Version: 1.0\r\n"));
        assert!(text.contains("Content-Type: text/plain; charset=utf-8"));
        assert!(text.contains("Content-Transfer-Encoding: base64"));
        assert!(text.ends_with("\r\n"), "the body ends with a CRLF, so the SMTP `.` is on its own line");
        assert_eq!(composed.recipients, 1);
        assert_eq!(composed.message_id, composed.message_id.to_lowercase());
        assert!(composed.message_id.ends_with("@example.com>"));
        // The body decodes back to exactly what was asked for.
        let bodies = decoded_bodies(&composed.bytes);
        assert_eq!(bodies.len(), 1);
        assert_eq!(String::from_utf8(bodies[0].clone()).unwrap(), "Segue o relatório.\n\nObrigada.");
    }

    #[test]
    fn an_attachment_is_a_second_part_with_its_name_and_own_base64() {
        let from = Mailbox::parse("me@example.com").unwrap();
        let mut verified = verified(&["ana@example.com"], &["bia@example.org"], "Fatura", "Segue.");
        verified.attachments.push(Attachment { filename: "fatura.txt".into(), mime: "text/plain".into(), bytes: b"fatura 42".to_vec() });
        let composed = compose(&from, &verified, "dedupe", 1_793_959_200_000);
        let text = String::from_utf8(composed.bytes.clone()).unwrap();
        assert!(text.contains("multipart/mixed; boundary=\"=_wa_email_"));
        assert!(text.contains("Content-Disposition: attachment; filename=\"fatura.txt\""));
        assert_eq!(composed.recipients, 2, "to and cc both count");
        assert!(text.contains("Cc: <bia@example.org>"));
        let bodies = decoded_bodies(&composed.bytes);
        assert_eq!(bodies.len(), 2);
        assert_eq!(String::from_utf8(bodies[0].clone()).unwrap(), "Segue.");
        assert_eq!(bodies[1], b"fatura 42");
    }

    #[test]
    fn no_header_line_is_over_the_hard_limit_and_none_is_two_lines() {
        let from = Mailbox::parse("me@example.com").unwrap();
        let many: Vec<String> = (0..20).map(|i| format!("destinatario.numero.{i}@a-rather-long-domain.example.com")).collect();
        let verified = verified(&many.iter().map(String::as_str).collect::<Vec<_>>(), &[], &"a".repeat(300), "corpo");
        let composed = compose(&from, &verified, "dedupe", 1_793_959_200_000);
        let text = String::from_utf8(composed.bytes).unwrap();
        let (headers, _) = text.split_once("\r\n\r\n").unwrap();
        for line in headers.split("\r\n") {
            assert!(line.len() <= 998, "line over the RFC 5322 limit: {} bytes", line.len());
        }
        // Unfolding the headers gives back one To: value with every recipient.
        let unfolded = headers.replace("\r\n ", " ");
        let to_line = unfolded.split("\r\n").find(|line| line.starts_with("To: ")).unwrap();
        assert_eq!(to_line.matches("<").count(), 20);
        // The subject is one (folded, encoded) header, not a line the body could be injected into.
        let subject_lines = headers.split("\r\n").filter(|line| line.starts_with("Subject:")).count();
        assert_eq!(subject_lines, 1);
    }

    #[test]
    fn an_ascii_subject_is_sent_exactly_as_written_and_a_reply_carries_its_reference() {
        let from = Mailbox::parse("me@example.com").unwrap();
        let mut verified = verified(&["ana@example.com"], &[], "Re: fatura", "ok");
        verified.in_reply_to = Some("<abc@example.com>".into());
        let composed = compose(&from, &verified, "dedupe", 0);
        let text = String::from_utf8(composed.bytes).unwrap();
        assert!(text.contains("\r\nSubject: Re: fatura\r\n"));
        assert!(text.contains("\r\nIn-Reply-To: <abc@example.com>\r\n"));
        assert!(text.contains("\r\nReferences: <abc@example.com>\r\n"));
    }

    #[test]
    fn the_message_id_is_stable_for_a_request_and_differs_for_another() {
        let from = Mailbox::parse("me@example.com").unwrap();
        let verified = verified(&["ana@example.com"], &[], "s", "b");
        let first = compose(&from, &verified, "key-a", 1_000);
        assert_eq!(first.message_id, compose(&from, &verified, "key-a", 1_000).message_id, "a retry carries the same id");
        assert_ne!(first.message_id, compose(&from, &verified, "key-b", 1_000).message_id);
        assert_ne!(first.message_id, compose(&from, &verified, "key-a", 2_000).message_id);
        assert!(!first.message_id.contains(' '));
    }

    #[test]
    fn the_date_formatter_is_the_inverse_of_the_parser() {
        for ms in [0, 1_793_959_200_000, 1_000_000_000_000, 2_000_000_000_000] {
            let formatted = format_date(ms);
            assert_eq!(crate::mime::parse_date(&formatted), Some(ms), "{formatted}");
        }
        assert_eq!(format_date(0), "Thu, 01 Jan 1970 00:00:00 +0000");
    }
}
