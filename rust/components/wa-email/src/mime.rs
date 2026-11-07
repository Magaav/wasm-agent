//! A small, bounded RFC 5322 + MIME reader: enough of one to index mail honestly.
//!
//! It reads the bytes an IMAP `BODY.PEEK[]` fetch returns and produces what the index keeps: the
//! envelope, the subject, the text body and the attachment metadata. It is not a mail client: it does
//! not render, it does not fetch a part from the server, and it never writes anything anywhere.
//!
//! The rules that matter for this connector:
//!
//! * **Bounded.** Every list and string is capped (`MAX_PARTS`, `MAX_TEXT`, attachment bytes), so a
//!   hostile message cannot turn into unbounded memory in a component with a memory grant.
//! * **No secret in the error path.** A malformed part is skipped and noted, never reported with the
//!   bytes attached: the caller logs counts (see `telemetry`).
//! * **Text is text.** `text/plain` wins, `text/html` is a fallback with the tags removed, and a
//!   message with neither still gets an indexed record (so a search can find it by subject or sender).
use base64::Engine as _;
use wa_email_index::{Address, AttachmentMeta, Record, MAX_SNIPPET};

/// Most MIME parts one message may have before the rest is ignored (and said so).
pub const MAX_PARTS: usize = 64;
/// Most boundary nesting.
const MAX_DEPTH: usize = 6;
/// Most header bytes read before the reader gives up on the header block.
const MAX_HEAD: usize = 256 * 1024;
/// An attachment bigger than this keeps its metadata but not its bytes.
pub const MAX_ATTACHMENT: usize = wa_email_index::keys::MAX_MEDIA;
/// Longest filename kept.
const MAX_FILENAME: usize = 200;

/// One attachment as the reader found it: the metadata and (when it fits) the bytes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ParsedAttachment {
    pub filename: String,
    pub mime: String,
    /// The part's position (`1.2`), so a later fetch can name exactly this part.
    pub part: String,
    /// The decoded bytes, empty when the attachment was too large to keep.
    pub bytes: Vec<u8>,
    /// `sha256` of the decoded bytes (16 hex): the media handle, and it exists even when the bytes
    /// were too large to keep.
    pub sha256: String,
    /// The decoded size, even when the bytes were dropped.
    pub size: u64,
    /// False when `bytes` is empty because the attachment was too large.
    pub stored: bool,
}

/// What one raw message says.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Parsed {
    pub from: Address,
    pub to: Vec<Address>,
    pub cc: Vec<Address>,
    pub subject: String,
    pub message_id: Option<String>,
    pub in_reply_to: Option<String>,
    pub references: Vec<String>,
    /// The `Date` header in Unix ms, when it parsed.
    pub date_ms: Option<i64>,
    pub text: String,
    pub text_truncated: bool,
    pub snippet: String,
    pub attachments: Vec<ParsedAttachment>,
    /// Parts that were skipped (too many, too deep, unreadable). A count, for the log.
    pub skipped_parts: u32,
}

impl Parsed {
    /// Fill the record the index stores: the reader's fields plus the server's envelope facts.
    pub fn into_record(self, mailbox: &str, uid: u32, uid_validity: u32, received_ms: i64, flags: Vec<String>, max_text: usize) -> (Record, Vec<Vec<u8>>) {
        let attachments: Vec<AttachmentMeta> = self
            .attachments
            .iter()
            .map(|attachment| AttachmentMeta {
                filename: attachment.filename.clone(),
                mime: attachment.mime.clone(),
                size: attachment.size,
                sha256: attachment.sha256.clone(),
                part: attachment.part.clone(),
                stored: attachment.stored,
            })
            .collect();
        let bytes = self.attachments.iter().map(|attachment| attachment.bytes.clone()).collect();
        let record = Record {
            mailbox: wa_email_index::keys::name(mailbox),
            uid,
            uid_validity,
            message_id: self.message_id,
            from: self.from,
            to: self.to,
            cc: self.cc,
            subject: self.subject,
            received_ms,
            sent_ms: self.date_ms,
            in_reply_to: self.in_reply_to,
            snippet: snippet(&self.text),
            text: self.text.chars().take(max_text).collect(),
            text_truncated: self.text_truncated || self.text.chars().count() > max_text,
            attachments,
            flags,
        };
        (record, bytes)
    }
}

/// Parse one message. It never fails: an unreadable header block yields a record with what could be
/// read, because a message that arrived is a message the index should know about.
pub fn parse(raw: &[u8], max_text: usize) -> Parsed {
    let (head, body) = split_head_body(raw);
    let headers = parse_headers(head);
    let subject = header(&headers, "subject").map(|value| clamp(&decode_words(value), 400)).unwrap_or_default();
    let from = header(&headers, "from").map(parse_addresses).and_then(|mut list| if list.is_empty() { None } else { Some(list.remove(0)) }).unwrap_or_default();
    let to = header(&headers, "to").map(parse_addresses).unwrap_or_default();
    let cc = header(&headers, "cc").map(parse_addresses).unwrap_or_default();
    let message_id = header(&headers, "message-id").map(str::trim).filter(|id| !id.is_empty()).map(|id| clamp(id, 250));
    let in_reply_to = header(&headers, "in-reply-to").map(str::trim).filter(|id| !id.is_empty()).map(|id| clamp(id, 250));
    let references: Vec<String> = header(&headers, "references")
        .map(|value| value.split_whitespace().take(32).map(|id| clamp(id, 250)).collect())
        .unwrap_or_default();
    let date_ms = header(&headers, "date").and_then(parse_date);
    let mut reader = BodyReader { parts: 0, skipped: 0, attachments: Vec::new(), plain: None, html: None };
    reader.walk(&headers, body, "1", 0, max_text);
    let text = reader.plain.or_else(|| reader.html.map(|html| html_to_text(&html))).unwrap_or_default();
    let text_truncated = text.chars().count() > max_text;
    let text: String = text.chars().take(max_text).collect();
    Parsed {
        from,
        to,
        cc,
        subject,
        message_id,
        in_reply_to,
        references,
        date_ms,
        snippet: snippet(&text),
        text,
        text_truncated,
        attachments: reader.attachments,
        skipped_parts: reader.skipped,
    }
}

/// The first [`MAX_SNIPPET`] characters of the body with whitespace collapsed, so a search hit is one
/// line.
pub fn snippet(text: &str) -> String {
    let collapsed = text.split_whitespace().collect::<Vec<_>>().join(" ");
    collapsed.chars().take(MAX_SNIPPET).collect()
}

struct BodyReader {
    parts: usize,
    skipped: u32,
    attachments: Vec<ParsedAttachment>,
    plain: Option<String>,
    html: Option<String>,
}

impl BodyReader {
    fn walk(&mut self, headers: &[(String, String)], body: &[u8], part: &str, depth: usize, max_text: usize) {
        self.parts += 1;
        if self.parts > MAX_PARTS || depth > MAX_DEPTH {
            self.skipped += 1;
            return;
        }
        let (mime, params) = header(headers, "content-type").map(parse_content_type).unwrap_or_else(|| ("text/plain".to_string(), Vec::new()));
        let filename = header(headers, "content-disposition")
            .map(parse_content_disposition)
            .and_then(|(kind, params)| {
                let name = param(&params, "filename").or_else(|| param(&params, "name"));
                name.map(|name| (kind, name))
            })
            .or_else(|| param(&params, "name").map(|name| ("inline".to_string(), name)));
        let encoding = header(headers, "content-transfer-encoding").unwrap_or("7bit");
        if mime.starts_with("multipart/") {
            let Some(boundary) = param(&params, "boundary") else {
                self.skipped += 1;
                return;
            };
            for (index, chunk) in split_multipart(body, &boundary).into_iter().enumerate() {
                let (head, part_body) = split_head_body(chunk);
                let part_headers = parse_headers(head);
                let id = format!("{part}.{}", index + 1);
                self.walk(&part_headers, part_body, &id, depth + 1, max_text);
            }
            return;
        }
        let decoded = decode_transfer(encoding, body);
        let is_attachment = filename.as_ref().map(|(kind, _)| kind != "inline" || !mime.starts_with("text/")).unwrap_or(false) || !(mime.starts_with("text/") || mime == "message/rfc822");
        if is_attachment {
            let (_, name) = filename.unwrap_or_else(|| (String::new(), default_filename(&mime, self.attachments.len())));
            let keep = decoded.len() <= MAX_ATTACHMENT;
            let digest = sha256(&decoded);
            self.attachments.push(ParsedAttachment {
                filename: clamp(&decode_words(&name), MAX_FILENAME),
                mime: mime.clone(),
                part: part.to_string(),
                size: decoded.len() as u64,
                stored: keep,
                bytes: if keep { decoded } else { Vec::new() },
                sha256: digest,
            });
            return;
        }
        // The text body: `text/plain` wins over `text/html`; a second part of the same kind (a quoted
        // reply, a signature) is appended only while the text budget allows.
        let text = decode_charset(&decoded, &params);
        let bucket = if mime == "text/html" { &mut self.html } else { &mut self.plain };
        match bucket {
            Some(existing) => {
                if existing.chars().count() < max_text {
                    existing.push_str("\n\n");
                    existing.push_str(&text);
                }
            }
            None => *bucket = Some(text),
        }
    }
}

fn default_filename(mime: &str, index: usize) -> String {
    let extension = mime.split('/').nth(1).unwrap_or("bin").split(';').next().unwrap_or("bin").trim();
    format!("attachment-{}.{}", index + 1, extension.chars().filter(|c| c.is_ascii_alphanumeric()).collect::<String>())
}

/// Split a raw message into its header block and body at the first empty line.
pub fn split_head_body(raw: &[u8]) -> (&str, &[u8]) {
    let limit = raw.len().min(MAX_HEAD + 4);
    let head = &raw[..limit];
    if let Some(at) = find(head, b"\r\n\r\n") {
        (as_str(&head[..at]), &raw[(at + 4).min(raw.len())..])
    } else if let Some(at) = find(head, b"\n\n") {
        (as_str(&head[..at]), &raw[(at + 2).min(raw.len())..])
    } else {
        (as_str(head), &[])
    }
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|window| window == needle)
}

fn as_str(bytes: &[u8]) -> &str {
    // A header block that is not UTF-8 is read lossily: a broken encoding is not a reason to drop a
    // message from the index.
    std::str::from_utf8(bytes).unwrap_or("")
}

/// Unfold the header block into `(lowercase name, value)` pairs. A continuation line starts with
/// space or tab.
pub fn parse_headers(head: &str) -> Vec<(String, String)> {
    let mut headers: Vec<(String, String)> = Vec::new();
    for line in head.split('\n') {
        let line = line.trim_end_matches('\r');
        if line.is_empty() {
            continue;
        }
        if (line.starts_with(' ') || line.starts_with('\t')) && !headers.is_empty() {
            let last = headers.len() - 1;
            headers[last].1.push(' ');
            headers[last].1.push_str(line.trim_start());
            continue;
        }
        let Some((name, value)) = line.split_once(':') else { continue };
        if name.is_empty() || name.chars().any(|c| c.is_whitespace()) {
            continue;
        }
        headers.push((name.to_ascii_lowercase(), value.trim().to_string()));
    }
    headers
}

fn header<'a>(headers: &'a [(String, String)], name: &str) -> Option<&'a str> {
    headers.iter().find(|(key, _)| key == name).map(|(_, value)| value.as_str())
}

fn param(params: &[(String, String)], name: &str) -> Option<String> {
    params.iter().find(|(key, _)| key == name).map(|(_, value)| value.clone())
}

fn clamp(text: &str, max: usize) -> String {
    let flat: String = text.chars().filter(|c| !c.is_control()).collect();
    flat.chars().take(max).collect()
}

/// Parse `text/plain; charset=utf-8; boundary="x"` into the type and its parameters.
pub fn parse_content_type(value: &str) -> (String, Vec<(String, String)>) {
    let mut parts = split_quoted(value, ';');
    let mime = parts.next().unwrap_or("text/plain").trim().to_ascii_lowercase();
    let mut params = Vec::new();
    for part in parts {
        let Some((key, value)) = part.split_once('=') else { continue };
        let key = key.trim().to_ascii_lowercase();
        let value = value.trim().trim_matches('"').to_string();
        if !key.is_empty() {
            params.push((key, value));
        }
    }
    (if mime.is_empty() { "text/plain".to_string() } else { mime }, params)
}

/// Parse `attachment; filename="x"` into `(kind, params)`.
fn parse_content_disposition(value: &str) -> (String, Vec<(String, String)>) {
    let mut parts = split_quoted(value, ';');
    let kind = parts.next().unwrap_or("inline").trim().to_ascii_lowercase();
    let mut params = Vec::new();
    for part in parts {
        let Some((key, value)) = part.split_once('=') else { continue };
        params.push((key.trim().to_ascii_lowercase(), value.trim().trim_matches('"').to_string()));
    }
    (kind, params)
}

/// Split on `separator` outside double quotes.
fn split_quoted(text: &str, separator: char) -> impl Iterator<Item = &str> {
    let mut out = Vec::new();
    let mut start = 0usize;
    let mut quoted = false;
    for (index, c) in text.char_indices() {
        match c {
            '"' => quoted = !quoted,
            c if c == separator && !quoted => {
                out.push(&text[start..index]);
                start = index + c.len_utf8();
            }
            _ => {}
        }
    }
    out.push(&text[start..]);
    out.into_iter()
}

/// Split a multipart body on its boundary, dropping the preamble and the epilogue.
pub fn split_multipart<'a>(body: &'a [u8], boundary: &str) -> Vec<&'a [u8]> {
    let marker = format!("--{boundary}");
    let mut spans = Vec::new();
    let mut search_from = 0usize;
    let mut start: Option<usize> = None;
    while let Some(at) = find(&body[search_from..], marker.as_bytes()) {
        let at = search_from + at;
        if let Some(open) = start {
            let mut end = at;
            // The CRLF before a boundary belongs to the boundary, not to the part.
            if end >= 2 && &body[end - 2..end] == b"\r\n" {
                end -= 2;
            } else if end >= 1 && &body[end - 1..end] == b"\n" {
                end -= 1;
            }
            spans.push(&body[open..end]);
        }
        let after = at + marker.len();
        // `--boundary--` is the closing marker; nothing after it is a part.
        if body[after..].starts_with(b"--") {
            start = None;
            break;
        }
        // Skip the rest of the boundary line, then the part starts after that CRLF.
        let mut open = after;
        while open < body.len() && body[open] != b'\n' {
            open += 1;
        }
        if open >= body.len() {
            break;
        }
        start = Some(open + 1);
        search_from = open + 1;
    }
    if let Some(open) = start {
        spans.push(&body[open..]);
    }
    spans
}

/// Decode a `Content-Transfer-Encoding` body.
pub fn decode_transfer(encoding: &str, body: &[u8]) -> Vec<u8> {
    match encoding.trim().to_ascii_lowercase().as_str() {
        "base64" => decode_base64(body),
        "quoted-printable" => decode_quoted_printable(body),
        _ => body.to_vec(),
    }
}

fn decode_base64(body: &[u8]) -> Vec<u8> {
    let compact: String = body.iter().filter(|byte| !byte.is_ascii_whitespace()).map(|byte| *byte as char).collect();
    let mut padded = compact.clone();
    while !padded.len().is_multiple_of(4) {
        padded.push('=');
    }
    base64::engine::general_purpose::STANDARD
        .decode(padded.as_bytes())
        .or_else(|_| base64::engine::general_purpose::STANDARD_NO_PAD.decode(compact.as_bytes()))
        .unwrap_or_default()
}

fn decode_quoted_printable(body: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(body.len());
    let mut index = 0usize;
    while index < body.len() {
        let byte = body[index];
        if byte == b'=' {
            // `=\r\n` (or `=\n`) is a soft line break: nothing is emitted.
            if index + 1 < body.len() && body[index + 1] == b'\r' && index + 2 < body.len() && body[index + 2] == b'\n' {
                index += 3;
                continue;
            }
            if index + 1 < body.len() && body[index + 1] == b'\n' {
                index += 2;
                continue;
            }
            if index + 2 < body.len() {
                let hex = std::str::from_utf8(&body[index + 1..index + 3]).ok();
                if let Some(value) = hex.and_then(|hex| u8::from_str_radix(hex, 16).ok()) {
                    out.push(value);
                    index += 3;
                    continue;
                }
            }
            out.push(byte);
            index += 1;
            continue;
        }
        out.push(byte);
        index += 1;
    }
    out
}

/// Decode `=?utf-8?B?…?=` / `=?utf-8?Q?…?=` words in a header value.
pub fn decode_words(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    let mut rest = value;
    let mut after_word = false;
    while let Some(start) = rest.find("=?") {
        if !rest.is_char_boundary(start) {
            break;
        }
        // RFC 2047: whitespace between two adjacent encoded words is part of the encoding, not of the
        // text, so `…Relatório_?= =?…mensal?=` is "Relatório mensal" and not "Relatório  mensal".
        if !(after_word && rest[..start].trim().is_empty()) {
            out.push_str(&rest[..start]);
        }
        let after = &rest[start + 2..];
        let Some((charset, rest2)) = after.split_once('?') else {
            out.push_str(&rest[start..]);
            return out;
        };
        let Some((encoding, rest3)) = rest2.split_once('?') else {
            out.push_str(&rest[start..]);
            return out;
        };
        let Some((text, rest4)) = rest3.split_once("?=") else {
            out.push_str(&rest[start..]);
            return out;
        };
        let _ = charset;
        match encoding.to_ascii_uppercase().as_str() {
            "B" => {
                let bytes = decode_base64(text.as_bytes());
                out.push_str(&String::from_utf8_lossy(&bytes));
            }
            "Q" => {
                let bytes = decode_quoted_printable(text.replace('_', " ").as_bytes());
                out.push_str(&String::from_utf8_lossy(&bytes));
            }
            _ => out.push_str(text),
        }
        after_word = true;
        rest = rest4;
    }
    out.push_str(rest);
    out
}

/// Parse an address list: `Ana Silva <ana@example.com>, "Bia" <bia@example.org>, carol@example.net`.
pub fn parse_addresses(value: &str) -> Vec<Address> {
    let mut out = Vec::new();
    for part in split_quoted(value, ',') {
        let part = part.trim();
        if part.is_empty() {
            continue;
        }
        let decoded = decode_words(part);
        let (name, addr) = match (decoded.rfind('<'), decoded.rfind('>')) {
            (Some(open), Some(close)) if close > open => {
                let name = decoded[..open].trim().trim_matches('"').trim().to_string();
                (if name.is_empty() { None } else { Some(name) }, decoded[open + 1..close].trim().to_string())
            }
            _ => (None, decoded.trim().to_string()),
        };
        if addr.is_empty() || addr.chars().any(|c| c.is_control()) {
            continue;
        }
        out.push(Address::new(name.as_deref(), &clamp(&addr, 254)));
        if out.len() >= 64 {
            break;
        }
    }
    out
}

/// Decode a text part's charset: UTF-8 (or unspecified) directly, everything else lossily.
fn decode_charset(bytes: &[u8], params: &[(String, String)]) -> String {
    let charset = param(params, "charset").unwrap_or_else(|| "utf-8".to_string()).to_ascii_lowercase();
    match charset.as_str() {
        "utf-8" | "utf8" | "us-ascii" | "ascii" | "iso-8859-1" | "latin1" | "windows-1252" | "" => String::from_utf8_lossy(bytes).to_string(),
        _ => String::from_utf8_lossy(bytes).to_string(),
    }
}

/// A rough HTML to text: `<script>`/`<style>` blocks and tags are removed, the common entities are
/// decoded, whitespace is collapsed. A reader, not a renderer.
pub fn html_to_text(html: &str) -> String {
    let mut text = String::with_capacity(html.len());
    let lower = html.to_ascii_lowercase();
    let mut index = 0usize;
    while index < html.len() {
        // A script or a style block is not text, and its content is not either.
        let mut skipped = false;
        for (open, close) in [("<script", "</script>"), ("<style", "</style>")] {
            if lower[index..].starts_with(open) {
                match lower[index..].find(close) {
                    Some(end) => {
                        index += end + close.len();
                        skipped = true;
                    }
                    None => index = html.len(),
                }
                break;
            }
        }
        if skipped {
            continue;
        }
        if lower[index..].starts_with('<') {
            // A tag (or a comment): drop it, and keep a space so `a<b>c` is not `ac`.
            match lower[index..].find('>') {
                Some(end) => {
                    index += end + 1;
                    text.push(' ');
                }
                None => index = html.len(),
            }
            continue;
        }
        // Copy up to the next tag, on character boundaries.
        let step = html[index..].chars().next().map(char::len_utf8).unwrap_or(1);
        text.push_str(&html[index..index + step]);
        index += step;
    }
    let decoded = text
        .replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'");
    decoded.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Parse an RFC 5322 `Date` header into Unix milliseconds. Deliberately forgiving: a mail client that
/// writes `GMT` or omits the weekday is not a reason to lose the timestamp, and an unparseable date is
/// `None` (the index falls back to the server's INTERNALDATE).
pub fn parse_date(value: &str) -> Option<i64> {
    let tokens: Vec<&str> = value.split(|c: char| c == ',' || c.is_whitespace()).map(str::trim).filter(|token| !token.is_empty()).collect();
    let mut day = None;
    let mut month = None;
    let mut year = None;
    let mut time = None;
    let mut offset_minutes = None;
    for token in tokens {
        if let Some((hours, minutes, seconds)) = parse_time(token) {
            time = Some((hours, minutes, seconds));
        } else if let Some(value) = month_of(token) {
            month = Some(value);
        } else if token.len() == 4 && token.chars().all(|c| c.is_ascii_digit()) {
            year = token.parse::<i64>().ok();
        } else if token.chars().all(|c| c.is_ascii_digit()) && token.len() <= 2 && day.is_none() {
            day = token.parse::<i64>().ok();
        } else if let Some(minutes) = parse_zone(token) {
            offset_minutes = Some(minutes);
        }
    }
    let (day, month, year, (hours, minutes, seconds)) = (day?, month?, year?, time?);
    if !(1..=31).contains(&day) || !(0..=23).contains(&hours) || !(0..=59).contains(&minutes) || !(0..=60).contains(&seconds) {
        return None;
    }
    let days = days_from_civil(year, month, day);
    let seconds_since_epoch = days * 86_400 + hours * 3_600 + minutes * 60 + seconds - offset_minutes.unwrap_or(0) * 60;
    Some(seconds_since_epoch * 1_000)
}

fn parse_time(token: &str) -> Option<(i64, i64, i64)> {
    let mut parts = token.split(':');
    let hours = parts.next()?.parse::<i64>().ok()?;
    let minutes = parts.next()?.parse::<i64>().ok()?;
    let seconds = parts.next().unwrap_or("0");
    let seconds = seconds.chars().take_while(char::is_ascii_digit).collect::<String>();
    let seconds = if seconds.is_empty() { 0 } else { seconds.parse::<i64>().ok()? };
    if parts.next().is_some() {
        return None;
    }
    Some((hours, minutes, seconds))
}

fn month_of(token: &str) -> Option<i64> {
    let month = match token.to_ascii_lowercase().as_str() {
        "jan" => 1,
        "feb" => 2,
        "mar" => 3,
        "apr" => 4,
        "may" => 5,
        "jun" => 6,
        "jul" => 7,
        "aug" => 8,
        "sep" => 9,
        "oct" => 10,
        "nov" => 11,
        "dec" => 12,
        _ => return None,
    };
    Some(month)
}

fn parse_zone(token: &str) -> Option<i64> {
    match token.to_ascii_uppercase().as_str() {
        "GMT" | "UTC" | "UT" | "Z" => return Some(0),
        // Obsolete US zone names, still written by old clients.
        "EST" => return Some(-300),
        "EDT" => return Some(-240),
        "CST" => return Some(-360),
        "CDT" => return Some(-300),
        "MST" => return Some(-420),
        "MDT" => return Some(-360),
        "PST" => return Some(-480),
        "PDT" => return Some(-420),
        _ => {}
    }
    let (sign, rest) = match token.chars().next()? {
        '+' => (1, &token[1..]),
        '-' => (-1, &token[1..]),
        _ => return None,
    };
    let digits: String = rest.chars().filter(|c| c.is_ascii_digit()).collect();
    if digits.len() != 4 {
        return None;
    }
    let hours = digits[..2].parse::<i64>().ok()?;
    let minutes = digits[2..].parse::<i64>().ok()?;
    if hours > 23 || minutes > 59 {
        return None;
    }
    Some(sign * (hours * 60 + minutes))
}

/// Howard Hinnant's `days_from_civil`, so the date math is a formula and not a leap-year table.
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = if year >= 0 { year } else { year - 399 } / 400;
    let year_of_era = year - era * 400;
    let day_of_year = (153 * (if month > 2 { month - 3 } else { month + 9 }) + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

fn sha256(bytes: &[u8]) -> String {
    // The media handle: the first 16 hex of `sha256(decoded bytes)`, the same digest
    // `wa-email-index` mints a `keys::media` entry from.
    wa_email_index::hash16(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SIMPLE: &[u8] = b"From: Ana Silva <ana@example.com>\r\nTo: me@example.com\r\nSubject: Relat\xc3\xb3rio\r\nMessage-ID: <abc@example.com>\r\nDate: Wed, 06 Nov 2026 10:00:00 +0000\r\n\r\nSegue o relat\xc3\xb3rio.\r\n";

    #[test]
    fn the_envelope_the_subject_the_date_and_the_text_are_read() {
        let parsed = parse(SIMPLE, 8_000);
        assert_eq!(parsed.from.display(), "Ana Silva <ana@example.com>");
        assert_eq!(parsed.to.len(), 1);
        assert_eq!(parsed.to[0].addr, "me@example.com");
        assert_eq!(parsed.subject, "Relatório");
        assert_eq!(parsed.message_id.as_deref(), Some("<abc@example.com>"));
        assert_eq!(parsed.text.trim(), "Segue o relatório.");
        assert_eq!(parsed.snippet, "Segue o relatório.");
        // 2026-11-06T10:00:00Z
        assert_eq!(parsed.date_ms, Some(1_793_959_200_000));
        assert!(parsed.attachments.is_empty());
        assert_eq!(parsed.skipped_parts, 0);
    }

    #[test]
    fn a_folded_header_and_an_rfc2047_subject_are_unfolded_and_decoded() {
        let raw = b"From: =?UTF-8?B?QW5hIFNpbHZh?= <ana@example.com>\r\nSubject: =?UTF-8?Q?Relat=C3=B3rio_?=\r\n  =?UTF-8?Q?mensal?=\r\n\r\ncorpo\r\n";
        let parsed = parse(raw, 8_000);
        assert_eq!(parsed.subject, "Relatório mensal", "folded and encoded words are one subject");
        assert_eq!(parsed.from.name.as_deref(), Some("Ana Silva"));
        assert_eq!(parsed.from.addr, "ana@example.com");
    }

    #[test]
    fn transfer_encodings_are_decoded() {
        let base64_body = b"From: a@example.com\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\nU2VndWUgbyByZWxhdMOzcmlvLg==\r\n";
        assert_eq!(parse(base64_body, 8_000).text.trim(), "Segue o relatório.");
        let qp = b"From: a@example.com\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nSegue o relat=C3=B3rio=2E\r\nE a segunda linha com um =\r\nbreak suave.\r\n";
        let text = parse(qp, 8_000).text;
        assert!(text.contains("Segue o relatório."), "{text}");
        assert!(text.contains("um break suave"), "a soft line break joins the line: {text}");
        // Identity encodings are the body as it arrived.
        let plain = b"From: a@example.com\r\n\r\nacao\r\n";
        assert_eq!(parse(plain, 8_000).text.trim(), "acao");
    }

    #[test]
    fn a_multipart_message_with_an_attachment_is_split_into_text_and_attachment() {
        let raw = b"From: Ana <ana@example.com>\r\nSubject: Fatura\r\nContent-Type: multipart/mixed; boundary=\"fronteira\"\r\n\r\npreamble\r\n--fronteira\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nSegue a fatura em anexo.\r\n--fronteira\r\nContent-Type: text/plain; name=\"fatura.txt\"\r\nContent-Disposition: attachment; filename=\"fatura.txt\"\r\nContent-Transfer-Encoding: base64\r\n\r\nZmF0dXJhIDQy\r\n--fronteira--\r\nepilogue\r\n";
        let parsed = parse(raw, 8_000);
        assert_eq!(parsed.text.trim(), "Segue a fatura em anexo.");
        assert_eq!(parsed.attachments.len(), 1);
        let attachment = &parsed.attachments[0];
        assert_eq!(attachment.filename, "fatura.txt");
        assert_eq!(attachment.mime, "text/plain");
        assert_eq!(attachment.bytes, b"fatura 42");
        assert_eq!(attachment.size, 9);
        assert!(attachment.stored);
        assert_eq!(attachment.part, "1.2");
        // The attachment's text is not in the body: a search must not find it there.
        assert!(!parsed.text.contains("fatura 42"));
    }

    #[test]
    fn an_html_only_message_is_reduced_to_text_and_a_message_with_no_text_is_still_a_record() {
        let html = b"From: a@example.com\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<html><body><p>Nota <b>fiscal</b></p><script>var x=1;</script></body></html>\r\n";
        let parsed = parse(html, 8_000);
        assert_eq!(parsed.text, "Nota fiscal", "tags go, and `<script>` content with them");
        let empty = parse(b"From: a@example.com\r\nSubject: vazio\r\n\r\n", 8_000);
        assert_eq!(empty.text, "");
        assert_eq!(empty.snippet, "");
        assert_eq!(empty.subject, "vazio");
    }

    #[test]
    fn the_text_budget_is_enforced_and_said_so() {
        let body = "palavra ".repeat(2_000);
        let raw = format!("From: a@example.com\r\n\r\n{body}");
        let parsed = parse(raw.as_bytes(), 100);
        assert_eq!(parsed.text.chars().count(), 100);
        assert!(parsed.text_truncated);
        // The snippet is the first characters of what was kept, one line.
        assert_eq!(parsed.snippet, snippet(&parsed.text));
        assert!(parsed.snippet.len() <= MAX_SNIPPET * 4);
    }

    #[test]
    fn a_large_attachment_keeps_metadata_and_not_bytes_and_says_which() {
        let big = base64::engine::general_purpose::STANDARD.encode(vec![b'x'; MAX_ATTACHMENT + 10]);
        let raw = format!("From: a@example.com\r\nContent-Type: multipart/mixed; boundary=b\r\n\r\n--b\r\nContent-Type: text/plain\r\n\r\ncorpo\r\n--b\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=\"video.bin\"\r\nContent-Transfer-Encoding: base64\r\n\r\n{big}\r\n--b--\r\n");
        let parsed = parse(raw.as_bytes(), 8_000);
        assert_eq!(parsed.attachments.len(), 1);
        let attachment = &parsed.attachments[0];
        assert_eq!(attachment.filename, "video.bin");
        assert_eq!(attachment.size as usize, MAX_ATTACHMENT + 10);
        assert!(!attachment.stored);
        assert!(attachment.bytes.is_empty(), "the examined bytes are not kept");
        assert_eq!(attachment.sha256.len(), 16, "the handle is a digest of the whole attachment, kept or not");
        assert_eq!(parsed.text.trim(), "corpo");
    }

    #[test]
    fn addresses_are_parsed_with_and_without_names() {
        let list = parse_addresses("Ana Silva <ana@example.com>, carol@example.net");
        assert_eq!(list.len(), 2);
        assert_eq!(list[0].display(), "Ana Silva <ana@example.com>");
        assert_eq!(list[1].display(), "carol@example.net");
        // A quoted name that contains a comma is one address, not two.
        let list = parse_addresses("\"Silva, Ana\" <ana@example.com>");
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].name.as_deref(), Some("Silva, Ana"));
        // A malformed entry is dropped, not invented.
        assert!(parse_addresses("").is_empty());
        assert_eq!(parse_addresses("lixo").len(), 1, "a bare token is kept as an address and shown as written");
        let parsed = parse(b"From: a@example.com\r\nTo: ,\r\n\r\nx", 100);
        assert!(parsed.to.is_empty());
    }

    #[test]
    fn dates_are_parsed_for_the_shapes_mail_clients_write() {
        assert_eq!(parse_date("Wed, 06 Nov 2026 10:00:00 +0000"), Some(1_793_959_200_000));
        assert_eq!(parse_date("6 Nov 2026 07:00:00 -0300"), Some(1_793_959_200_000), "the same instant in another zone");
        assert_eq!(parse_date("Wed, 06 Nov 2026 10:00:00 GMT"), Some(1_793_959_200_000));
        assert_eq!(parse_date("Wed, 06 Nov 2026 10:00:00 UTC"), Some(1_793_959_200_000));
        // An unparseable or absurd date is `None`, and the index falls back to INTERNALDATE.
        assert_eq!(parse_date("not a date"), None);
        assert_eq!(parse_date(""), None);
        assert_eq!(parse_date("32 Nov 2026 10:00:00 +0000"), None);
        assert_eq!(parse_date("06 Nov 2026 25:00:00 +0000"), None);
    }

    #[test]
    fn the_content_type_parser_keeps_quoted_parameters() {
        let (mime, params) = parse_content_type("multipart/mixed; boundary=\"a;b\"; charset=UTF-8");
        assert_eq!(mime, "multipart/mixed");
        assert_eq!(param(&params, "boundary").as_deref(), Some("a;b"), "a semicolon inside quotes is part of the value");
        assert_eq!(param(&params, "charset").as_deref(), Some("UTF-8"));
        let (mime, _) = parse_content_type("");
        assert_eq!(mime, "text/plain", "no type is text/plain: a readable default, not a guess at an attachment");
    }

    #[test]
    fn the_multipart_splitter_drops_the_preamble_and_the_epilogue() {
        let body = b"preambulo\r\n--x\r\nA\r\n--x\r\nB\r\n--x--\r\nepilogo";
        let parts = split_multipart(body, "x");
        assert_eq!(parts.len(), 2);
        assert_eq!(parts[0], b"A");
        assert_eq!(parts[1], b"B");
    }

    #[test]
    fn a_record_is_filled_from_the_message_and_the_server_facts() {
        let parsed = parse(SIMPLE, 8_000);
        let (record, bytes) = parsed.into_record("inbox", 7, 3, 1_700_000_000_000, vec!["\\Seen".into()], 8_000);
        assert_eq!(record.mailbox, "INBOX");
        assert_eq!(record.uid, 7);
        assert_eq!(record.uid_validity, 3);
        assert_eq!(record.received_ms, 1_700_000_000_000);
        assert_eq!(record.sent_ms, Some(1_793_959_200_000));
        assert_eq!(record.subject, "Relatório");
        assert_eq!(record.flags, vec!["\\Seen".to_string()]);
        assert!(bytes.is_empty());
        // And it is searchable through the index's own folding.
        assert!(wa_email_index::fold(&record.subject).contains("relatorio"));
    }
}
