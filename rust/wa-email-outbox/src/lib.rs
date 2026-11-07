//! The email send path: one outgoing message somebody asked for.
//!
//! Same architecture as the WhatsApp explicit send (`rust/wa-whatsapp-outbox`,
//! `docs/SERVICE-COMPONENTS.md`): a request is a **job** on the shared durable queue (`wa:queue`,
//! queue name [`QUEUE`]), not a hidden side path. The node enqueues it after the `email.send` policy
//! check (`docs/GRANT-POLICY.md`), the `wa-email` component consumes it and reports
//! `done(message id)` or `fail(reason)`, and an operator reads the state back with the same id.
//!
//! This crate is the part both ends must agree on, and it is deliberately small and pure:
//!
//! * [`Mailbox`] - one address, as an addr-spec, and why anything else is refused. The connector
//!   sends to exact addresses only: a display name (`Ana <a@b>`), a group alias, a bare word or
//!   anything with a control character is a refusal with a stable code, never a guess. A `Mailbox`
//!   can never carry a CR/LF, so a header cannot be injected through it.
//! * [`Request`] - `{to, cc?, subject, body, in_reply_to?, attachments?}` as it travels in the job
//!   payload, plus the dedupe key: `sha256(to|cc|subject|body|in_reply_to)`.
//! * [`decide`] - what the worker does with a taken job: send these bytes, or refuse. This is where
//!   the freshness window and the [`RateLimiter`] live, so a request the queue never expired is still
//!   never sent late, and a burst cannot outrun the connector's own budget.
//! * [`Outcome`] - what `done` carries (the server's message id) and what `email_send_status` reads
//!   back, so "sent, here is its id" needs no mailbox access.
//! * [`audit_target`] - the *hashed* recipient list: the audit trail and every log line keep a
//!   digest of the address, never the address itself.
//! * [`Secret`] / [`redact`] - the one type a credential is allowed to live in. Its `Debug`,
//!   `Display` and `redact` output never reveal the value, so a log line built with `{}` or `{:?}`
//!   cannot leak a password.
//!
//! Nothing here logs, and nothing here stores text: the payload is the only place a message's subject
//! and body live, and they live in the queue's kv until the job is settled and reaped
//! (`docs/QUEUE.md`).
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, VecDeque};
use std::fmt;

/// The queue every explicit send travels on.
pub const QUEUE: &str = "email.outbox";
/// A request nobody picked up within this window is never sent (`fresh_for_ms`): mail that was asked
/// for five minutes ago is still mail, but a queue that stalls must not deliver yesterday's answer.
pub const FRESH_MS: i64 = 300_000;
/// Attempts before a retryable SMTP failure becomes final.
pub const MAX_ATTEMPTS: u32 = 3;
/// Most recipients (`to` + `cc`) one request may name.
pub const MAX_RECIPIENTS: usize = 50;
/// Longest subject, in characters.
pub const MAX_SUBJECT: usize = 900;
/// Longest body, in characters (about 100 KiB of UTF-8 worst case, inside the queue's payload bound).
pub const MAX_BODY: usize = 40_000;
/// Most attachments one request may carry, and their total decoded size. Bigger files are the
/// media-download path (a component-owned file, not a queue payload) and are refused here by name.
pub const MAX_ATTACHMENTS: usize = 3;
pub const MAX_ATTACHMENT_BYTES: usize = 24 * 1024;
/// Longest `in_reply_to` value (a message id).
pub const MAX_REPLY_TO: usize = 250;
/// Shipped rate policy: 6 sends a minute, 100 a day, one every two seconds at most. Mail is a slower
/// channel than chat and a runaway agent loop must cost a fraction of what the WhatsApp cap allows.
pub const DEFAULT_PER_MINUTE: u32 = 6;
pub const DEFAULT_PER_DAY: u32 = 100;
pub const DEFAULT_MIN_INTERVAL_MS: u64 = 2_000;

/// One exact address, split into its two parts and validated.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Mailbox {
    /// The local part, case preserved (SMTP treats it as case sensitive).
    pub local: String,
    /// The domain, lowercased: DNS is case insensitive and one mailbox must have one digest.
    pub domain: String,
}

impl Mailbox {
    /// Parse an addr-spec: `local@domain`.
    ///
    /// The accept list is deliberately narrower than RFC 5322: dot-atom local part, ASCII only, a
    /// hostname-shaped domain. Everything else is refused with a stable code so the tool answer, the
    /// log word and the test name the same thing:
    ///
    /// * `bad_to` - empty, no `@`, whitespace or a control character, a display name, a comma-separated
    ///   list, an unquoted local part, a leading/trailing/double dot, a bad label;
    /// * `unsupported_to` - a shape SMTP here cannot do yet: a non-ASCII (SMTPUTF8) address, a domain
    ///   literal (`user@[10.0.0.1]`), a route (`@relay:user@host`) or a quoted local part.
    pub fn parse(text: &str) -> Result<Mailbox, Refusal> {
        if text.is_empty() {
            return Err(Refusal::new("bad_to", "empty address: pass an exact addr-spec (local@domain)"));
        }
        if text.trim() != text {
            return Err(Refusal::new("bad_to", "address has surrounding whitespace"));
        }
        if text.contains('"') {
            return Err(Refusal::new("unsupported_to", "quoted local part is not supported"));
        }
        if text.chars().any(|c| c.is_control() || c.is_whitespace()) {
            return Err(Refusal::new("bad_to", "address contains whitespace or a control character"));
        }
        if text.chars().count() > 254 {
            return Err(Refusal::new("bad_to", "address is longer than 254 characters"));
        }
        if !text.is_ascii() {
            return Err(Refusal::new(
                "unsupported_to",
                "non-ASCII address (SMTPUTF8 is not implemented here; send to the ACE/punycode form)",
            ));
        }
        if text.matches('@').count() != 1 {
            return Err(Refusal::new("bad_to", "address must contain exactly one @"));
        }
        let (local, domain) = text.split_once('@').expect("exactly one @");
        if local.is_empty() || domain.is_empty() {
            return Err(Refusal::new("bad_to", "address has an empty local part or domain"));
        }
        if local.chars().count() > 64 {
            return Err(Refusal::new("bad_to", "local part is longer than 64 characters"));
        }
        if local.starts_with('.') || local.ends_with('.') || local.contains("..") {
            return Err(Refusal::new("bad_to", "local part has an empty dot-atom"));
        }
        for c in local.chars() {
            let atom = c.is_ascii_alphanumeric() || "!#$%&'*+-/=?^_`{|}~.".contains(c);
            if !atom {
                return Err(Refusal::new("bad_to", format!("local part has an illegal character {c:?}")));
            }
        }
        // Domain literals and source routes are a different transport, not a typo to repair.
        if domain.starts_with('[') || text.starts_with('@') {
            return Err(Refusal::new("unsupported_to", "domain literals and source routes are not supported"));
        }
        if domain.chars().count() > 253 {
            return Err(Refusal::new("bad_to", "domain is longer than 253 characters"));
        }
        for label in domain.split('.') {
            if label.is_empty() {
                return Err(Refusal::new("bad_to", "domain has an empty label"));
            }
            if label.starts_with('-') || label.ends_with('-') {
                return Err(Refusal::new("bad_to", "domain label starts or ends with a hyphen"));
            }
            if label.chars().count() > 63 {
                return Err(Refusal::new("bad_to", "domain label is longer than 63 characters"));
            }
            if !label.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
                return Err(Refusal::new("bad_to", "domain label has an illegal character"));
            }
        }
        Ok(Mailbox { local: local.to_string(), domain: domain.to_ascii_lowercase() })
    }

    /// `local@domain` - the address as it is written in a header (never with a display name).
    pub fn addr(&self) -> String {
        format!("{}@{}", self.local, self.domain)
    }

    /// The same address, as the angle-addr a header carries: `<local@domain>`.
    pub fn header(&self) -> String {
        format!("<{}>", self.addr())
    }
}

impl fmt::Display for Mailbox {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.addr())
    }
}

/// Why a request was refused. `code` is a stable word (`bad_to`, `empty_subject`, `rate_limited`, …)
/// and [`Refusal::error`] is the tool-facing spelling of it (`email_send_bad_to`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refusal {
    pub code: &'static str,
    pub detail: String,
}

impl Refusal {
    pub fn new(code: &'static str, detail: impl Into<String>) -> Refusal {
        Refusal { code, detail: detail.into() }
    }

    /// The stable tool error word: `email_send_<code>`.
    pub fn error(&self) -> String {
        format!("email_send_{}", self.code)
    }
}

impl fmt::Display for Refusal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.error(), self.detail)
    }
}

/// One attachment: a filename, a type and the bytes, base64 in the payload.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Attachment {
    pub filename: String,
    pub mime: String,
    #[serde(with = "base64_bytes")]
    pub bytes: Vec<u8>,
}

/// One send request, exactly as it travels in the job payload.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Request {
    #[serde(default)]
    pub to: Vec<String>,
    #[serde(default)]
    pub cc: Vec<String>,
    #[serde(default)]
    pub subject: String,
    #[serde(default)]
    pub body: String,
    #[serde(default)]
    pub in_reply_to: Option<String>,
    #[serde(default)]
    pub attachments: Vec<Attachment>,
}

/// A validated request: the addresses are parsed, the header-safe text is cleaned, and every bound has
/// been checked. Only this type is handed to the composer, so an unvalidated field cannot reach a
/// wire.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Verified {
    pub to: Vec<Mailbox>,
    pub cc: Vec<Mailbox>,
    pub subject: String,
    pub body: String,
    pub in_reply_to: Option<String>,
    pub attachments: Vec<Attachment>,
}

impl Verified {
    /// Every recipient, `to` then `cc`, deduplicated case-insensitively on the whole address.
    pub fn recipients(&self) -> Vec<&Mailbox> {
        let mut seen = std::collections::BTreeSet::new();
        self.to.iter().chain(self.cc.iter()).filter(|mailbox| seen.insert(mailbox.addr().to_ascii_lowercase())).collect()
    }
}

impl Request {
    /// The payload as it is enqueued.
    pub fn encode(&self) -> Vec<u8> {
        serde_json::to_vec(self).unwrap_or_default()
    }

    /// Read a payload back. A payload this crate cannot parse is the queue's failure to report, never
    /// a message to guess at.
    pub fn decode(payload: &[u8]) -> Result<Request, String> {
        serde_json::from_slice(payload).map_err(|error| format!("payload is not an email send request: {error}"))
    }

    /// Check every field, or say which one is wrong and why.
    pub fn validate(&self) -> Result<Verified, Refusal> {
        if self.to.is_empty() {
            return Err(Refusal::new("bad_to", "no recipient: pass at least one address in `to`"));
        }
        let mut to = Vec::with_capacity(self.to.len());
        for raw in &self.to {
            to.push(Mailbox::parse(raw)?);
        }
        let mut cc = Vec::with_capacity(self.cc.len());
        for raw in &self.cc {
            cc.push(Mailbox::parse(raw).map_err(|mut refusal| {
                // A cc refusal keeps its own word, so a caller can tell which list was wrong.
                refusal.detail = format!("cc: {}", refusal.detail);
                Refusal { code: "bad_cc", detail: refusal.detail }
            })?);
        }
        if to.len() + cc.len() > MAX_RECIPIENTS {
            return Err(Refusal::new("too_many_recipients", format!("{} addresses (at most {MAX_RECIPIENTS})", to.len() + cc.len())));
        }
        let mut decoded = Vec::with_capacity(self.attachments.len());
        let mut total = 0usize;
        for attachment in &self.attachments {
            if attachment.filename.is_empty() || attachment.filename.chars().count() > 200 {
                return Err(Refusal::new("bad_attachment", "attachment filename is empty or longer than 200 characters"));
            }
            if attachment.filename.chars().any(|c| c.is_control() || "\"\\/:*?<>|".contains(c)) {
                return Err(Refusal::new("bad_attachment", "attachment filename has a control character or a shell/path metacharacter"));
            }
            if !is_mime(&attachment.mime) {
                return Err(Refusal::new("bad_attachment", format!("attachment type {:?} is not type/subtype", attachment.mime.chars().take(40).collect::<String>())));
            }
            total += attachment.bytes.len();
            decoded.push(attachment.clone());
        }
        if decoded.len() > MAX_ATTACHMENTS {
            return Err(Refusal::new("too_many_attachments", format!("{} attachments (at most {MAX_ATTACHMENTS})", decoded.len())));
        }
        if total > MAX_ATTACHMENT_BYTES {
            return Err(Refusal::new(
                "attachment_too_large",
                format!("attachments total {total} bytes (at most {MAX_ATTACHMENT_BYTES}); larger files go through the media download path"),
            ));
        }
        let subject = self.subject.trim().to_string();
        if subject.chars().count() > MAX_SUBJECT {
            return Err(Refusal::new("subject_too_long", format!("subject is longer than {MAX_SUBJECT} characters")));
        }
        if subject.chars().any(|c| c.is_control()) {
            return Err(Refusal::new("bad_subject", "subject contains a control character (it becomes one header line)"));
        }
        let body = self.body.clone();
        if body.chars().count() > MAX_BODY {
            return Err(Refusal::new("body_too_long", format!("body is longer than {MAX_BODY} characters")));
        }
        if body.chars().any(|c| c == '\0') {
            return Err(Refusal::new("bad_body", "body contains a NUL"));
        }
        let reply_to = match self.in_reply_to.as_deref().map(str::trim) {
            // An empty `in_reply_to` means "no reply", not a refusal: a caller that passes "" means
            // nothing, the same rule the WhatsApp outbox applies to `reply_to`.
            None | Some("") => None,
            Some(id) => {
                if id.chars().count() > MAX_REPLY_TO || id.chars().any(|c| c.is_control() || c.is_whitespace()) {
                    return Err(Refusal::new("bad_reply_to", "in_reply_to is not a message id (control/whitespace) or is too long"));
                }
                Some(id.to_string())
            }
        };
        Ok(Verified { to, cc, subject, body, in_reply_to: reply_to, attachments: decoded })
    }

    /// The producer's idempotency key: `sha256(to|cc|subject|body|in_reply_to)`. The same request
    /// repeated is the same job, so a caller that retried after a timeout does not send twice.
    pub fn dedupe_key(&self) -> String {
        let mut hasher = Sha256::new();
        hasher.update(self.to.join(",").as_bytes());
        hasher.update(b"|");
        hasher.update(self.cc.join(",").as_bytes());
        hasher.update(b"|");
        hasher.update(self.subject.as_bytes());
        hasher.update(b"|");
        hasher.update(self.body.as_bytes());
        hasher.update(b"|");
        hasher.update(self.in_reply_to.as_deref().unwrap_or("").as_bytes());
        hex(&hasher.finalize())
    }
}

fn is_mime(text: &str) -> bool {
    if text.len() > 127 || !text.is_ascii() {
        return false;
    }
    let Some((kind, subtype)) = text.split_once('/') else { return false };
    let ok = |part: &str| {
        !part.is_empty()
            && part.chars().all(|c| c.is_ascii_alphanumeric() || "+.-_".contains(c))
            && !part.starts_with(['.', '+', '-', '_'])
            && !part.ends_with(['.', '+', '-', '_'])
    };
    ok(kind) && ok(subtype)
}

/// What the worker does with a job it just took.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Decision {
    Send(Verified),
    /// Refused before a byte reaches SMTP. `settle` is what the queue hears (`fail(reason)`), and the
    /// reason is a stable word, never the message.
    Refuse(Refusal),
}

/// Decide what to do with one taken job.
///
/// * The freshness window is checked first: a request the queue kept longer than [`FRESH_MS`] is
///   refused, because a send that sat in a stalled queue is a send that could now be wrong.
/// * Then the rate limit: the connector's own budget, per domain and in total, is charged *before*
///   the SMTP dialog, so a refusal settles as a failure and nothing is sent.
pub fn decide(request: &Request, age_ms: i64, limiter: &mut RateLimiter, now_ms: u64) -> Decision {
    if age_ms > FRESH_MS {
        return Decision::Refuse(Refusal::new(
            "stale",
            format!("queued {} ms ago (window {FRESH_MS} ms): a stale send is never delivered", age_ms.max(0)),
        ));
    }
    let verified = match request.validate() {
        Ok(verified) => verified,
        Err(refusal) => return Decision::Refuse(refusal),
    };
    let domains: Vec<&str> = {
        let mut seen = std::collections::BTreeSet::new();
        verified.recipients().iter().filter(|mailbox| seen.insert(mailbox.domain.clone())).map(|mailbox| mailbox.domain.as_str()).collect()
    };
    if let Err(denial) = limiter.try_acquire(&domains, now_ms) {
        return Decision::Refuse(Refusal::new("rate_limited", denial.describe()));
    }
    Decision::Send(verified)
}

/// The outbox's own budget. The node's `email.send` policy rule is the first gate
/// (`docs/GRANT-POLICY.md`); this is the second, and it is the one the worker can enforce without a
/// policy interface: a component that could ask "may I?" would be a component that could answer "yes".
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RatePolicy {
    pub per_minute: u32,
    pub per_day: u32,
    pub min_interval_ms: u64,
}

impl Default for RatePolicy {
    fn default() -> Self {
        RatePolicy { per_minute: DEFAULT_PER_MINUTE, per_day: DEFAULT_PER_DAY, min_interval_ms: DEFAULT_MIN_INTERVAL_MS }
    }
}

/// A refusal from the limiter: which budget ran out and how long to wait.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RateDenial {
    pub reason: &'static str,
    pub retry_after_ms: u64,
}

impl RateDenial {
    fn describe(&self) -> String {
        format!("{}: retry in {} ms", self.reason, self.retry_after_ms)
    }
}

/// Sliding-window limiter: a one-minute window, a day cap, a minimum gap between sends, and a
/// per-domain window so one bad recipient cannot starve every other one.
#[derive(Clone, Debug)]
pub struct RateLimiter {
    policy: RatePolicy,
    /// Send times inside the last minute, oldest first (bounded by `per_minute` + 1).
    minute: VecDeque<u64>,
    /// Sends in the current day.
    day: u32,
    /// Start of the day the counter belongs to (Unix ms, UTC midnight).
    day_start_ms: u64,
    last: Option<u64>,
    per_domain: BTreeMap<String, VecDeque<u64>>,
    per_domain_minute: u32,
}

/// How many sends one domain may receive in a minute: half the global budget, at least one.
fn per_domain_limit(policy: RatePolicy) -> u32 {
    (policy.per_minute / 2).max(1)
}

impl RateLimiter {
    pub fn new(policy: RatePolicy) -> RateLimiter {
        RateLimiter {
            policy,
            minute: VecDeque::new(),
            day: 0,
            day_start_ms: 0,
            last: None,
            per_domain: BTreeMap::new(),
            per_domain_minute: per_domain_limit(policy),
        }
    }

    pub fn policy(&self) -> RatePolicy {
        self.policy
    }

    fn day_of(now_ms: u64) -> u64 {
        now_ms - (now_ms % 86_400_000)
    }

    /// Charge one send to every budget, or refuse and charge nothing.
    pub fn try_acquire(&mut self, domains: &[&str], now_ms: u64) -> Result<(), RateDenial> {
        let day = Self::day_of(now_ms);
        if day != self.day_start_ms {
            self.day_start_ms = day;
            self.day = 0;
        }
        while let Some(at) = self.minute.front() {
            if now_ms.saturating_sub(*at) >= 60_000 {
                self.minute.pop_front();
            } else {
                break;
            }
        }
        if let Some(last) = self.last {
            let elapsed = now_ms.saturating_sub(last);
            if elapsed < self.policy.min_interval_ms {
                return Err(RateDenial {
                    reason: "min_interval",
                    retry_after_ms: self.policy.min_interval_ms - elapsed,
                });
            }
        }
        if self.minute.len() as u32 >= self.policy.per_minute {
            let oldest = self.minute.front().copied().unwrap_or(now_ms);
            return Err(RateDenial {
                reason: "capability_rate_limited",
                retry_after_ms: 60_000u64.saturating_sub(now_ms.saturating_sub(oldest)).max(1),
            });
        }
        if self.day >= self.policy.per_day {
            return Err(RateDenial { reason: "daily_cap", retry_after_ms: (day + 86_400_000).saturating_sub(now_ms).max(1) });
        }
        for domain in domains {
            let window = self.per_domain.entry((*domain).to_string()).or_default();
            while let Some(at) = window.front() {
                if now_ms.saturating_sub(*at) >= 60_000 {
                    window.pop_front();
                } else {
                    break;
                }
            }
            if window.len() as u32 >= self.per_domain_minute {
                let oldest = window.front().copied().unwrap_or(now_ms);
                return Err(RateDenial {
                    reason: "target_rate_limited",
                    retry_after_ms: 60_000u64.saturating_sub(now_ms.saturating_sub(oldest)).max(1),
                });
            }
        }
        // Nothing refused: charge everything.
        self.minute.push_back(now_ms);
        self.day += 1;
        self.last = Some(now_ms);
        for domain in domains {
            self.per_domain.entry((*domain).to_string()).or_default().push_back(now_ms);
        }
        Ok(())
    }
}

/// The audit target for one send: `email:<n>rcpt:<digest>` where the digest is the first 16 hex of
/// `sha256(addr)` per recipient, joined by `,`. The policy engine's audit trail therefore counts
/// recipients and can correlate a repeat sender without ever holding an address.
pub fn audit_target(recipients: &[&Mailbox]) -> String {
    let digests: Vec<String> = recipients.iter().map(|mailbox| hash_address(&mailbox.addr())).collect();
    format!("email:{}rcpt:{}", recipients.len(), digests.join(","))
}

/// One address, hashed for the audit trail and the logs.
pub fn hash_address(address: &str) -> String {
    let digest = Sha256::digest(address.trim().to_ascii_lowercase().as_bytes());
    hex(&digest)[..16].to_string()
}

/// What `done` carries: the message id the server assigned, so `email_send_status` can answer "sent,
/// here is its id" without touching the mailbox.
pub fn done_result(message_id: &str) -> Vec<u8> {
    serde_json::to_vec(&serde_json::json!({ "message_id": message_id })).unwrap_or_default()
}

/// Read the message id out of a settled job's result.
pub fn parse_done(result: Option<&[u8]>) -> Option<String> {
    let value: serde_json::Value = serde_json::from_slice(result?).ok()?;
    value.get("message_id")?.as_str().map(str::to_string).filter(|id| !id.is_empty())
}

/// The status answer `email_send_status` returns, from the job the queue stores. Never carries text:
/// an id, a state, a count and stable words.
pub fn status(id: u64, state: &str, attempts: u32, result: Option<&[u8]>, last_error: Option<&str>) -> serde_json::Value {
    match state {
        "done" => {
            let message_id = parse_done(result);
            serde_json::json!({
                "ok": true,
                "id": id,
                "state": "done",
                "attempts": attempts,
                "message_id": message_id,
                "delivered": message_id.is_some(),
            })
        }
        "dead" | "expired" => serde_json::json!({
            "ok": true,
            "id": id,
            "state": state,
            // The queue's reason is one line and is a word, not message text; a reason that somehow
            // grew is truncated here rather than echoed whole.
            "reason": last_error.unwrap_or(if state == "expired" { "expired" } else { "failed" }).chars().take(160).collect::<String>(),
            "attempts": attempts,
        }),
        other => serde_json::json!({
            "ok": true,
            "id": id,
            "state": if other == "leased" { "sending" } else { "queued" },
            "attempts": attempts,
        }),
    }
}

/// A credential. The value can only leave through [`Secret::expose`], and every other way of printing
/// it is masked, so a log line that formats a config cannot leak a password.
#[derive(Clone, PartialEq, Eq)]
pub struct Secret(String);

impl Secret {
    pub fn new(value: impl Into<String>) -> Secret {
        Secret(value.into())
    }

    /// The value, for the one call that needs it (an SMTP/IMAP AUTH exchange).
    pub fn expose(&self) -> &str {
        &self.0
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

impl fmt::Debug for Secret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // Lengths are not printed either: a password's length is a hint, and a hint is not needed.
        f.write_str("Secret(***)")
    }
}

impl fmt::Display for Secret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("***")
    }
}

/// Replace every occurrence of any secret in `text`. The last line of defence before a log line: a
/// message that a credential was found in a server's answer is worth logging, the credential is not.
pub fn redact(text: &str, secrets: &[&str]) -> String {
    let mut out = text.to_string();
    for secret in secrets {
        if secret.len() >= 3 {
            out = out.replace(secret, "***");
        }
    }
    out
}

fn hex(bytes: &[u8]) -> String {
    let mut text = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        text.push_str(&format!("{byte:02x}"));
    }
    text
}

/// `base64` for the attachment bytes: the job payload is JSON, so the bytes have to be text.
mod base64_bytes {
    use base64::Engine as _;
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(bytes: &[u8], serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&base64::engine::general_purpose::STANDARD.encode(bytes))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Vec<u8>, D::Error> {
        let text = String::deserialize(deserializer)?;
        base64::engine::general_purpose::STANDARD.decode(text).map_err(serde::de::Error::custom)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(to: &str, subject: &str, body: &str) -> Request {
        Request { to: vec![to.into()], cc: Vec::new(), subject: subject.into(), body: body.into(), in_reply_to: None, attachments: Vec::new() }
    }

    #[test]
    fn an_addr_spec_is_parsed_and_the_domain_is_canonicalized() {
        let mailbox = Mailbox::parse("Ana.Silva+tag@Example.COM").unwrap();
        assert_eq!(mailbox.local, "Ana.Silva+tag", "the local part keeps its case");
        assert_eq!(mailbox.domain, "example.com", "DNS is case insensitive");
        assert_eq!(mailbox.addr(), "Ana.Silva+tag@example.com");
        assert_eq!(mailbox.header(), "<Ana.Silva+tag@example.com>");
        // The fake servers the tests use answer on a single-label host, so that shape has to parse.
        assert!(Mailbox::parse("user@localhost").is_ok());
    }

    #[test]
    fn an_address_that_is_not_an_exact_addr_spec_is_refused_with_a_code() {
        for (text, code) in [
            ("", "bad_to"),
            ("   ", "bad_to"),
            ("ana@example.com ", "bad_to"),
            ("Ana <ana@example.com>", "bad_to"),
            ("ana", "bad_to"),
            ("@example.com", "bad_to"),
            ("ana@", "bad_to"),
            ("ana@example@com", "bad_to"),
            ("ana@@example.com", "bad_to"),
            ("ana silva@example.com", "bad_to"),
            ("ana@exa mple.com", "bad_to"),
            ("ana\r\n@example.com", "bad_to"),
            (".ana@example.com", "bad_to"),
            ("ana..silva@example.com", "bad_to"),
            ("ana@-example.com", "bad_to"),
            ("ana@example..com", "bad_to"),
            ("ana@example.com.", "bad_to"),
            ("aná@example.com", "unsupported_to"),
            ("ana@exämple.com", "unsupported_to"),
            ("ana@[127.0.0.1]", "unsupported_to"),
            ("\"ana silva\"@example.com", "unsupported_to"),
        ] {
            let refusal = Mailbox::parse(text).expect_err(text);
            assert_eq!(refusal.code, code, "{text:?}");
            assert_eq!(refusal.error(), format!("email_send_{code}"));
            assert!(!refusal.detail.is_empty());
        }
    }

    #[test]
    fn a_header_cannot_be_injected_through_an_address_or_a_subject() {
        // Every one of these is refused *before* the composer builds a header block.
        assert!(Mailbox::parse("ana@example.com\r\nBcc: evil@example.com").is_err());
        let mut inject = request("ana@example.com", "hello\r\nBcc: evil@example.com", "body");
        assert_eq!(inject.validate().unwrap_err().code, "bad_subject");
        inject.subject = "hello\tworld".into();
        assert_eq!(inject.validate().unwrap_err().code, "bad_subject");
        // A newline in the body is mail, not injection: headers are built from validated fields only.
        assert!(request("ana@example.com", "hello", "line one\nline two").validate().is_ok());
    }

    #[test]
    fn recipients_attachments_and_text_are_bounded() {
        assert_eq!(request("ana@example.com", "s", "b").validate().unwrap().to.len(), 1);
        let mut none = request("ana@example.com", "s", "b");
        none.to.clear();
        assert_eq!(none.validate().unwrap_err().code, "bad_to");
        let mut many = request("ana@example.com", "s", "b");
        many.to = (0..=MAX_RECIPIENTS).map(|i| format!("a{i}@example.com")).collect();
        assert_eq!(many.validate().unwrap_err().code, "too_many_recipients");
        let mut long = request("ana@example.com", &"x".repeat(MAX_SUBJECT + 1), "b");
        assert_eq!(long.validate().unwrap_err().code, "subject_too_long");
        long.subject = "ok".into();
        long.body = "x".repeat(MAX_BODY + 1);
        assert_eq!(long.validate().unwrap_err().code, "body_too_long");
        // An empty subject is allowed (a reply thread keeps the subject), it is just empty.
        assert_eq!(request("ana@example.com", "", "b").validate().unwrap().subject, "");
        // An empty `in_reply_to` is "no reply", not a refusal.
        let mut reply = request("ana@example.com", "s", "b");
        reply.in_reply_to = Some(String::new());
        assert!(reply.validate().unwrap().in_reply_to.is_none());
        reply.in_reply_to = Some("a b".into());
        assert_eq!(reply.validate().unwrap_err().code, "bad_reply_to");
        // One bad cc keeps its own word, so a caller knows which list was wrong.
        let mut cc = request("ana@example.com", "s", "b");
        cc.cc = vec!["nope".into()];
        assert_eq!(cc.validate().unwrap_err().code, "bad_cc");
    }

    #[test]
    fn attachments_are_bounded_and_survive_the_payload_round_trip() {
        let mut with = request("ana@example.com", "relatorio", "segue");
        with.attachments.push(Attachment { filename: "relatorio.txt".into(), mime: "text/plain".into(), bytes: b"acao\n".to_vec() });
        let verified = with.validate().unwrap();
        assert_eq!(verified.attachments[0].bytes, b"acao\n");
        let payload = with.encode();
        // The bytes are base64 in the payload, never raw: the payload is JSON.
        assert!(std::str::from_utf8(&payload).unwrap().contains("YWNhbwo="));
        assert_eq!(Request::decode(&payload).unwrap(), with);
        // A refusal by name and by size, never a silent truncation.
        with.attachments[0].filename = "a\"b.txt".into();
        assert_eq!(with.validate().unwrap_err().code, "bad_attachment");
        let mut big = request("ana@example.com", "s", "b");
        big.attachments = vec![Attachment { filename: "big.bin".into(), mime: "application/octet-stream".into(), bytes: vec![0; MAX_ATTACHMENT_BYTES + 1] }];
        assert_eq!(big.validate().unwrap_err().code, "attachment_too_large");
        let mut bad_mime = request("ana@example.com", "s", "b");
        bad_mime.attachments = vec![Attachment { filename: "x.txt".into(), mime: "text".into(), bytes: vec![1] }];
        assert_eq!(bad_mime.validate().unwrap_err().code, "bad_attachment");
    }

    #[test]
    fn the_dedupe_key_is_sha256_of_the_whole_request() {
        let plain = request("ana@example.com", "oi", "corpo");
        assert_eq!(plain.dedupe_key(), hex(&Sha256::digest(b"ana@example.com||oi|corpo|")));
        let mut reply = plain.clone();
        reply.in_reply_to = Some("<abc@example.com>".into());
        assert_ne!(reply.dedupe_key(), plain.dedupe_key(), "a reply is a different send");
        let mut other = plain.clone();
        other.to = vec!["ana@example.com".into(), "bia@example.com".into()];
        assert_ne!(other.dedupe_key(), plain.dedupe_key());
    }

    #[test]
    fn a_stale_job_and_a_spent_budget_are_refused_before_the_wire() {
        // per_minute 10 is five sends a minute for one domain (half the budget): the per-domain half
        // is what the sixth send meets, so this measures the limiter's own refusal and not a cap.
        let mut limiter = RateLimiter::new(RatePolicy { per_minute: 10, per_day: 10, min_interval_ms: 0 });
        let request = request("ana@example.com", "s", "b");
        match decide(&request, FRESH_MS + 1, &mut limiter, 1_000) {
            Decision::Refuse(refusal) => assert_eq!(refusal.code, "stale"),
            other => panic!("a stale job is never sent, got {other:?}"),
        }
        for i in 0..5 {
            match decide(&request, 0, &mut limiter, 1_000) {
                Decision::Send(verified) => assert_eq!(verified.to[0].addr(), "ana@example.com"),
                other => panic!("send {i} was refused: {other:?}"),
            }
        }
        match decide(&request, 0, &mut limiter, 1_000) {
            Decision::Refuse(refusal) => {
                assert_eq!(refusal.code, "rate_limited");
                assert!(refusal.detail.starts_with("target_rate_limited"), "{}", refusal.detail);
            }
            other => panic!("expected a rate refusal, got {other:?}"),
        }
        // A malformed payload taken off the queue still never reaches the wire.
        let bad = Request { to: vec!["nope".into()], ..Default::default() };
        assert!(matches!(decide(&bad, 0, &mut limiter, 1_000), Decision::Refuse(refusal) if refusal.code == "bad_to"));
    }

    #[test]
    fn the_limiter_charges_the_minute_the_day_the_gap_and_the_domain() {
        // One recipient domain per send, so this block measures the global budgets and not the
        // per-domain half (which the block below measures on its own).
        let mut limiter = RateLimiter::new(RatePolicy { per_minute: 4, per_day: 5, min_interval_ms: 1_000 });
        assert_eq!(limiter.try_acquire(&["s1.example"], 0), Ok(()));
        // The gap between two sends.
        let denial = limiter.try_acquire(&["s2.example"], 400).unwrap_err();
        assert_eq!(denial.reason, "min_interval");
        assert_eq!(denial.retry_after_ms, 600);
        assert_eq!(limiter.try_acquire(&["s2.example"], 1_000), Ok(()));
        assert_eq!(limiter.try_acquire(&["s3.example"], 2_000), Ok(()));
        assert_eq!(limiter.try_acquire(&["s4.example"], 3_000), Ok(()));
        // The fifth send inside the minute is over the per-minute cap.
        let denial = limiter.try_acquire(&["s5.example"], 4_000).unwrap_err();
        assert_eq!(denial.reason, "capability_rate_limited");
        assert_eq!(denial.retry_after_ms, 56_000);
        // A minute later the window has slid, so this one is allowed - and it is the day's last.
        assert_eq!(limiter.try_acquire(&["s5.example"], 61_000), Ok(()));
        let denial = limiter.try_acquire(&["s6.example"], 61_500).unwrap_err();
        assert_eq!(denial.reason, "min_interval", "the gap is checked before any budget");
        let denial = limiter.try_acquire(&["s6.example"], 63_000).unwrap_err();
        assert_eq!(denial.reason, "daily_cap");
        assert_eq!(denial.retry_after_ms, 86_400_000 - 63_000);
        // The next day is a clean day.
        assert_eq!(limiter.try_acquire(&["s6.example"], 86_400_000), Ok(()));
        // One domain cannot starve another: five sends to it in a minute hit the per-domain half.
        let mut limiter = RateLimiter::new(RatePolicy { per_minute: 10, per_day: 100, min_interval_ms: 0 });
        for i in 0..5 {
            assert_eq!(limiter.try_acquire(&["hot.example"], 1_000 + i), Ok(()), "send {i}");
        }
        let denial = limiter.try_acquire(&["hot.example"], 2_000).unwrap_err();
        assert_eq!(denial.reason, "target_rate_limited");
        assert_eq!(limiter.try_acquire(&["other.example"], 2_000), Ok(()), "a different domain still sends");
        // Several domains in one send are charged together, and a refusal charges none of them.
        let mut limiter = RateLimiter::new(RatePolicy { per_minute: 10, per_day: 100, min_interval_ms: 0 });
        assert_eq!(limiter.try_acquire(&["a.example", "b.example"], 1_000), Ok(()));
        assert_eq!(limiter.try_acquire(&["a.example"], 1_001), Ok(()));
        assert_eq!(limiter.try_acquire(&["b.example"], 1_002), Ok(()));
    }

    #[test]
    fn the_audit_trail_and_the_logs_keep_a_digest_never_an_address() {
        let ana = Mailbox::parse("Ana.Silva@Example.com").unwrap();
        let bia = Mailbox::parse("bia@example.org").unwrap();
        let target = audit_target(&[&ana, &bia]);
        assert!(target.starts_with("email:2rcpt:"));
        assert!(!target.contains('@'), "the audit target carries no address: {target}");
        assert!(!target.to_lowercase().contains("silva"));
        assert_eq!(hash_address("ana.silva@example.com"), hash_address("ANA.SILVA@example.com"));
        assert_eq!(hash_address("ana.silva@example.com").len(), 16);
    }

    #[test]
    fn a_secret_is_masked_in_every_formatting_and_in_redacted_text() {
        let secret = Secret::new("hunter2-correct-horse");
        assert_eq!(format!("{secret}"), "***");
        assert_eq!(format!("{secret:?}"), "Secret(***)");
        assert!(!format!("{secret:?} {secret}").contains("hunter2"));
        assert_eq!(secret.expose(), "hunter2-correct-horse");
        let line = format!("auth failed for {}", secret);
        assert_eq!(redact(&line, &[secret.expose()]), "auth failed for ***");
        // A server answer that echoes the password back is logged with the password removed.
        let answer = "535 5.7.8 bad credentials hunter2-correct-horse";
        assert_eq!(redact(answer, &[secret.expose()]), "535 5.7.8 bad credentials ***");
        // Very short secrets are not replaced (a 1-2 character string would mangle every line), and
        // such a secret is never usable here anyway: validation refuses a credential that short.
        assert_eq!(redact("abc", &["a"]), "abc");
    }

    #[test]
    fn the_status_answers_distinguish_queued_delivered_and_dead() {
        let done = status(7, "done", 1, Some(&done_result("<abc@example.com>")), None);
        assert_eq!(done["state"], "done");
        assert_eq!(done["message_id"], "<abc@example.com>");
        assert_eq!(done["delivered"], true);
        let done_without_id = status(7, "done", 1, None, None);
        assert_eq!(done_without_id["delivered"], false);
        let queued = status(8, "ready", 0, None, None);
        assert_eq!(queued["state"], "queued");
        assert_eq!(status(9, "leased", 1, None, None)["state"], "sending");
        let dead = status(10, "dead", 3, None, Some("smtp_5xx: no such user"));
        assert_eq!(dead["state"], "dead");
        assert_eq!(dead["reason"], "smtp_5xx: no such user");
        assert_eq!(status(11, "expired", 0, None, None)["reason"], "expired");
        // A reason longer than the bound is truncated, never echoed whole.
        let long = status(12, "dead", 1, None, Some(&"x".repeat(400)));
        assert_eq!(long["reason"].as_str().unwrap().len(), 160);
        // Nothing in any answer is message text: the keys are ids, states, counts and words.
        for answer in [done, queued, dead, long] {
            for key in ["body", "text", "subject", "to"] {
                assert!(answer.get(key).is_none(), "{key} must not be in a status answer");
            }
        }
    }

    #[test]
    fn a_payload_the_crate_cannot_read_is_an_error_not_a_guess() {
        assert!(Request::decode(b"not json").is_err());
        let empty = Request::default();
        assert_eq!(empty.validate().unwrap_err().code, "bad_to");
        // Every field defaults, so a payload that only carries `to` and `body` is still readable.
        let partial = Request::decode(br#"{"to":["ana@example.com"],"body":"oi"}"#).unwrap();
        assert_eq!(partial.validate().unwrap().subject, "");
    }
}
