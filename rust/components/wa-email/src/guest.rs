//! The service itself (host I/O only): config, credential, transport, bus, queue, lifecycle.
//!
//! One suspendable `run` and one loop, in the order that keeps mail moving and makes the connector's cost
//! visible:
//!
//! 1. one IMAP round (connect, select, fetch what is above the stored UID, index, publish
//!    `email.received`), then the sync state is written back;
//! 2. one outbox job (`email.outbox`: decide, compose, submit over SMTP, settle `done(message id)`);
//! 3. one query job (`email.query`: materialise the index, answer, settle `done(answer)`);
//! 4. wait `poll_seconds` (a `wasi:clocks` timer), and repeat until `lifecycle.stopping()`.
//!
//! Every wait is an awaited kernel call, so the runtime parks this task between rounds and an idle
//! connector costs one timer per poll interval - that is the number the optimization check measures
//! (`REPORT.md`). Nothing here logs mail: `telemetry::Line` can only carry numbers and codes.
use std::time::Duration;

use wa_email_index::{Record, MAX_SCAN};
use wa_email_outbox::{Secret, Request as SendRequest};

use crate::compose;
use crate::config::Config;
use crate::connector::{self, answer_query, deliver, sync_round, Link, LinkError, SendOutcome, SessionError};
use crate::imap::Imap;
use crate::reconnect::Backoff;
use crate::smtp::Smtp;
use crate::store::{error_text, KvStore};
use crate::telemetry::{sanitize, Line};
use crate::wa::bus::publisher::{self, Event as BusEvent};
use crate::wa::email::transport;
use crate::wa::kernel::{credentials, kv, lifecycle, log};
use crate::wa::queue::worker;
use crate::wasi::clocks::monotonic_clock;

/// The identity this component works queues as. A lease belongs to one name, and the host refuses a
/// settle from another, so this constant is the only place it is written.
const WORKER: &str = "wa-email";
/// How long one taken job is leased before the queue may hand it to somebody else.
const LEASE_MS: u64 = 30_000;
/// Most queue jobs one loop turn settles, so a busy outbox cannot starve the mailbox poll.
const JOBS_PER_TURN: u32 = 8;

/// The service's export target. `lib.rs` calls the generated `export!` on it, at the crate root, where
/// the macro's own paths resolve.
pub struct Service;

impl crate::exports::wa::kernel::service::Guest for Service {
    /// One suspendable call: the runtime parks it while it waits, and it returns when the supervisor asks
    /// it to stop (or when the configuration refuses to start it).
    async fn run(config: String) -> Result<(), String> {
        serve(config).await
    }
}

/// Milliseconds since the Unix epoch, from `wasi:clocks/system-clock` (the kernel's service world gives
/// the monotonic clock for waiting; a queue job's freshness window is wall time, so the wall clock is
/// imported for it in `wit/wa.wit`).
fn now_ms() -> i64 {
    let now = crate::wasi::clocks::system_clock::now();
    now.seconds.saturating_mul(1_000) + i64::from(now.nanoseconds / 1_000_000)
}

/// One awaited timer.
async fn wait_ms(ms: u64) {
    monotonic_clock::wait_for(ms.saturating_mul(1_000_000)).await;
}

/// One structured log line: the builder only accepts numbers and codes.
fn say(line: String) {
    log::write(log::Level::Info, "wa-email", &line);
}

/// One warning, same shape.
fn warn(line: String) {
    log::write(log::Level::Warn, "wa-email", &line);
}

async fn serve(raw: String) -> Result<(), String> {
    let config = match Config::parse(&raw) {
        Ok(config) => config,
        Err(error) => {
            // A config that cannot start is reported with the field, never with a value that might be a
            // password, and the component stops rather than running in a state nobody asked for.
            warn(Line::new("config_refused").word("code", error.code).word("detail", &sanitize(&error.detail, &[])).build());
            return Err(error.code.to_string());
        }
    };
    let password = match credentials::get(&config.credential) {
        Ok(value) => Secret::new(value),
        Err(error) => {
            // `refused` means the vault has no such name (or the grant does not cover it): an operator
            // action, not a retry.
            warn(Line::new("credential_missing").word("name", &config.credential).word("code", "email_credential_missing").word("detail", &error_word(error)).build());
            lifecycle::report(lifecycle::Health::Degraded, Some("email_credential_missing"));
            return Err("email_credential_missing".to_string());
        }
    };
    if let Err(code) = connector::check_credential(&password) {
        warn(Line::new("credential_refused").word("code", code).build());
        lifecycle::report(lifecycle::Health::Degraded, Some(code));
        return Err(code.to_string());
    }
    say(Line::new("start").word("imap", &config.imap.authority()).word("smtp", &config.smtp.authority()).word("mailbox", &config.mailbox).field("poll_s", config.poll_seconds).build());
    lifecycle::report(lifecycle::Health::Starting, Some("connecting"));

    let mut store = KvStore::new();
    let mut limiter = config.limiter();
    let mut backoff = Backoff::default();
    let mut last_uid: u32 = 0;
    let mut uid_validity: u32 = 0;
    loop {
        if lifecycle::stopping() {
            say(Line::new("stop").field("last_uid", u64::from(last_uid)).build());
            let _ = store.flush().await;
            return Ok(());
        }

        // ---- 1. the mailbox ----------------------------------------------------------------
        match mail_round(&config, &password, &mut store, last_uid, uid_validity).await {
            Ok(report) => {
                backoff.healthy(now_ms() as u64);
                last_uid = report.last_uid;
                uid_validity = report.uid_validity;
                lifecycle::report(lifecycle::Health::Ready, Some("mailbox synced"));
                say(Line::new("sync")
                    .field("uid_validity", u64::from(report.uid_validity))
                    .field("fetched", u64::from(report.fetched))
                    .field("indexed", u64::from(report.indexed))
                    .field("skipped", u64::from(report.skipped))
                    .field("last_uid", u64::from(report.last_uid))
                    .build());
            }
            Err(error) => {
                // The stable word is what a status answer reads; the detail is the host's own line with
                // the credential removed (`imap::quiet`, `smtp::quiet`).
                warn(Line::new("sync_failed").word("code", error.code()).word("detail", &detail_of(&error)).build());
                lifecycle::report(lifecycle::Health::Degraded, Some(error.code()));
                let wait = if error.retryable() { backoff.failure(now_ms() as u64) } else { backoff.permanent_failure().delay_ms() };
                wait_ms(wait).await;
                continue;
            }
        }

        // ---- 2. the outbox, then the queries -----------------------------------------------
        for _ in 0..JOBS_PER_TURN {
            if !outbox_job(&config, &password, &mut limiter).await {
                break;
            }
        }
        for _ in 0..JOBS_PER_TURN {
            if !query_job(&mut store).await {
                break;
            }
        }
        let _ = store.flush().await;

        // ---- 3. the wait that makes this component cheap when idle -------------------------
        wait_ms(config.poll_seconds.saturating_mul(1_000)).await;
    }
}

/// One IMAP round: connect over the kernel's TLS stream, resume from the stored floor, index what is new,
/// publish `email.received`, store the new floor.
async fn mail_round(config: &Config, password: &Secret, store: &mut KvStore, last_uid: u32, uid_validity: u32) -> Result<connector::SyncReport, SessionError> {
    let mut conn = transport::Connection::connect(config.imap.host.clone(), config.imap.port, config.imap.tls).await.map_err(|error| SessionError::Transport(error_word(error)))?;
    let mut link = KernelLink { conn: &mut conn };
    // The floor: the state the last successful round wrote, for this generation.
    let state_key = wa_email_index::keys::state(&config.mailbox, if uid_validity == 0 { 0 } else { uid_validity });
    let stored = conn_state(&state_key).await;
    let floor = connector::resume_floor(stored.as_deref(), uid_validity).max(last_uid);
    let mut imap = Imap::new(&config.mailbox, &config.user, password.clone());
    imap.seed_floor(floor);
    let mut records: Vec<Record> = Vec::new();
    let report = sync_round(&mut imap, &mut link, store, &config.mailbox, config.max_text, now_ms(), |record| records.push(record.clone())).await?;
    link.close().await;
    // The bus fact goes out after the round, one publish per new message: a subscriber that misses it
    // still finds the mail in the index, so a failed publish is logged and does not undo the round.
    for record in &records {
        publish_received(record).await;
    }
    // The floor, for the next round and for the next start.
    let state = connector::sync_state(&config.mailbox, &report, now_ms());
    if let Err(error) = kv::set(state_key, connector::encode_state(&state)).await {
        warn(Line::new("state_write_failed").word("detail", &error_word(error)).build());
    }
    Ok(report)
}

async fn conn_state(key: &[u8]) -> Option<Vec<u8>> {
    match kv::get(key.to_vec()).await {
        Ok(value) => value,
        Err(error) => {
            warn(Line::new("state_read_failed").word("detail", &error_word(error)).build());
            None
        }
    }
}

async fn publish_received(record: &Record) {
    let (topic, schema, schema_version, payload) = wa_email_index::received_event(record);
    let event = BusEvent {
        // The kernel stamps the id, the time and the source: a guest never names itself.
        id: 0,
        topic,
        ts_ms: 0,
        source: String::new(),
        schema,
        schema_version,
        trace: None,
        payload: serde_json::to_vec(&payload).unwrap_or_default(),
    };
    match publisher::publish(event).await {
        Ok(report) if report.dropped > 0 => {
            warn(Line::new("bus_dropped").field("uid", u64::from(record.uid)).field("dropped", u64::from(report.dropped)).build());
        }
        Ok(_) => {}
        Err(error) => {
            // A fact is not authority: the index still has the message, and `email_read` answers. Log the
            // refusal with its word and carry on.
            warn(Line::new("bus_refused").field("uid", u64::from(record.uid)).word("detail", &error_word(error)).build());
        }
    }
}

/// One outbox job: take, decide, compose, submit, settle. `false` means the queue had nothing.
async fn outbox_job(config: &Config, password: &Secret, limiter: &mut wa_email_outbox::RateLimiter) -> bool {
    let taken = match worker::take(wa_email_outbox::QUEUE.to_string(), WORKER.to_string(), Some(LEASE_MS)).await {
        Ok(worker::TakeOutcome::Taken(lease)) => lease,
        Ok(worker::TakeOutcome::Empty) => return false,
        Ok(worker::TakeOutcome::Busy(leased)) => {
            warn(Line::new("outbox_busy").field("leased", u64::from(leased)).build());
            return false;
        }
        Err(error) => {
            warn(Line::new("outbox_take_failed").word("detail", &error_word(error)).build());
            return false;
        }
    };
    let job = taken.job;
    let id = job.id;
    let request = match SendRequest::decode(&job.payload) {
        Ok(request) => request,
        Err(detail) => {
            // A payload this build cannot read is the producer's bug: settle it as a failure with the word,
            // never retry it into a send.
            let _ = worker::fail(wa_email_outbox::QUEUE.to_string(), id, WORKER.to_string(), "email_send_unreadable_payload".to_string()).await;
            warn(Line::new("outbox_unreadable").field("job", id).word("detail", &sanitize(&detail, &[])).build());
            return true;
        }
    };
    let age_ms = now_ms() - job.created_at_ms as i64;
    let verified = match wa_email_outbox::decide(&request, age_ms, limiter, now_ms() as u64) {
        wa_email_outbox::Decision::Refuse(refusal) => {
            // Refused before a byte reaches SMTP: settle with the stable word, never the message.
            let stored = format!("{}: {}", refusal.code, sanitize(&refusal.detail, &[password.expose()]));
            let _ = worker::fail(wa_email_outbox::QUEUE.to_string(), id, WORKER.to_string(), stored.chars().take(160).collect()).await;
            say(Line::new("outbox_refused").field("job", id).word("code", &refusal.error()).build());
            return true;
        }
        wa_email_outbox::Decision::Send(verified) => verified,
    };
    let dedupe = request.dedupe_key();
    let composed = compose::compose(&config.from, &verified, &dedupe, now_ms());
    // The audit trail keeps a digest of the recipients, never the addresses (`wa-email-outbox`).
    let audit = wa_email_outbox::audit_target(&verified.recipients());
    match transport::Connection::connect(config.smtp.host.clone(), config.smtp.port, config.smtp.tls).await {
        Ok(mut conn) => {
            let mut link = KernelLink { conn: &mut conn };
            let mut smtp = Smtp::new(&config.smtp.host, &config.user, password.clone(), &config.from, &verified, &composed);
            match deliver(&mut smtp, &mut link).await {
                Ok(SendOutcome::Sent { message_id, recipients }) => {
                    link.close().await;
                    let output = wa_email_outbox::done_result(&message_id);
                    if let Err(error) = worker::done(wa_email_outbox::QUEUE.to_string(), id, WORKER.to_string(), output).await {
                        // The message is out. Retrying the settle would risk a second send, so the lease is
                        // left to lapse and the operator sees the queue's own alert.
                        warn(Line::new("outbox_done_failed").field("job", id).word("detail", &error_word(error)).build());
                    }
                    say(Line::new("outbox_sent").field("job", id).field("recipients", recipients as u64).word("audit", &audit).build());
                }
                Ok(SendOutcome::Refused { code, detail, retryable }) => {
                    link.close().await;
                    let stored = format!("{}:{}", if retryable { "retry" } else { "permanent" }, sanitize(&format!("{code} {detail}"), &[password.expose()]));
                    let _ = worker::fail(wa_email_outbox::QUEUE.to_string(), id, WORKER.to_string(), stored.chars().take(160).collect()).await;
                    warn(Line::new("outbox_refused").field("job", id).word("code", code).build());
                }
                Err(error) => {
                    link.close().await;
                    let stored = format!("retry:{}", error.code());
                    let _ = worker::fail(wa_email_outbox::QUEUE.to_string(), id, WORKER.to_string(), stored).await;
                    warn(Line::new("outbox_failed").field("job", id).word("code", error.code()).word("detail", &detail_of(&error)).build());
                }
            }
        }
        Err(error) => {
            // The SMTP connection itself failed: retryable (the queue's backoff applies), settled as such.
            let _ = worker::fail(wa_email_outbox::QUEUE.to_string(), id, WORKER.to_string(), format!("retry:{}", error_word(error.clone()))).await;
            warn(Line::new("outbox_connect_failed").field("job", id).word("detail", &error_word(error)).build());
        }
    }
    true
}

/// One query job: take, materialise the index, answer, settle. `false` means the queue had nothing.
async fn query_job(store: &mut KvStore) -> bool {
    let taken = match worker::take(wa_email_index::QUEUE.to_string(), WORKER.to_string(), Some(LEASE_MS)).await {
        Ok(worker::TakeOutcome::Taken(lease)) => lease,
        Ok(worker::TakeOutcome::Empty) => return false,
        Ok(worker::TakeOutcome::Busy(_)) => return false,
        Err(error) => {
            warn(Line::new("query_take_failed").word("detail", &error_word(error)).build());
            return false;
        }
    };
    let job = taken.job;
    let id = job.id;
    let request = match wa_email_index::Request::decode(&job.payload) {
        Ok(request) => request,
        Err(_) => {
            let _ = worker::fail(wa_email_index::QUEUE.to_string(), id, WORKER.to_string(), "email_query_unreadable_payload".to_string()).await;
            return true;
        }
    };
    // The index is read into the view first: a search is bounded by `MAX_SCAN` records, which is the same
    // bound the answer carries (`wa-email-index`).
    if let Err(detail) = store.load_prefix(wa_email_index::keys::RECORD, MAX_SCAN).await {
        let _ = worker::fail(wa_email_index::QUEUE.to_string(), id, WORKER.to_string(), format!("email_query_kv_failed {detail}").chars().take(160).collect()).await;
        return true;
    }
    let answer = match answer_query(store, &request) {
        Ok(answer) => answer,
        Err(detail) => {
            let _ = worker::fail(wa_email_index::QUEUE.to_string(), id, WORKER.to_string(), sanitize(&detail, &[]).chars().take(160).collect()).await;
            return true;
        }
    };
    let output = serde_json::to_vec(&answer).unwrap_or_default();
    if let Err(error) = worker::done(wa_email_index::QUEUE.to_string(), id, WORKER.to_string(), output).await {
        warn(Line::new("query_done_failed").field("job", id).word("detail", &error_word(error)).build());
    }
    say(Line::new("query_answered").field("job", id).field("bytes", serde_json::to_string(&answer).map(|text| text.len() as u64).unwrap_or(0)).build());
    true
}

/// The guest's [`Link`]: one `wa:email/transport` connection (TLS in the kernel).
struct KernelLink<'a> {
    conn: &'a mut transport::Connection,
}

impl Link for KernelLink<'_> {
    fn read(&mut self, max: u32) -> impl std::future::Future<Output = Result<Vec<u8>, LinkError>> {
        async move { self.conn.read(max).await.map_err(error_word).map_err(LinkError) }
    }

    fn write(&mut self, bytes: &[u8]) -> impl std::future::Future<Output = Result<(), LinkError>> {
        let data = bytes.to_vec();
        async move { self.conn.write(data).await.map_err(error_word).map_err(LinkError) }
    }

    fn close(&mut self) -> impl std::future::Future<Output = ()> {
        async move { self.conn.close() }
    }
}

/// A kernel answer as one stable word plus its reason (the reason is the host's, never a payload).
///
/// The kernel, the queue and the bus each declare their own `error` variant with the same four core
/// shapes, so this trait is what lets one log call name all three without a `match` at every site.
trait Word {
    fn word(&self) -> String;
}

impl Word for crate::wa::kernel::types::Error {
    fn word(&self) -> String {
        match self {
            crate::wa::kernel::types::Error::Refused(reason) => format!("refused {reason}"),
            crate::wa::kernel::types::Error::Again => "again".to_string(),
            crate::wa::kernel::types::Error::Closed => "closed".to_string(),
            crate::wa::kernel::types::Error::Failed(reason) => format!("failed {reason}"),
        }
    }
}

impl Word for crate::wa::bus::types::Error {
    fn word(&self) -> String {
        match self {
            crate::wa::bus::types::Error::Refused(reason) => format!("refused {reason}"),
            crate::wa::bus::types::Error::Again => "again".to_string(),
            crate::wa::bus::types::Error::Closed => "closed".to_string(),
            crate::wa::bus::types::Error::Failed(reason) => format!("failed {reason}"),
        }
    }
}

impl Word for crate::wa::queue::types::Error {
    fn word(&self) -> String {
        use crate::wa::queue::types::Error as Q;
        match self {
            Q::Refused(reason) => format!("refused {reason}"),
            Q::Invalid(reason) => format!("invalid {reason}"),
            Q::NotFound => "not-found".to_string(),
            Q::LeaseLost => "lease-lost".to_string(),
            Q::TooLarge(reason) => format!("too-large {reason}"),
            Q::Full((queue, ready, limit)) => format!("full {queue} {ready}/{limit}"),
            Q::Again => "again".to_string(),
            Q::Failed(reason) => format!("failed {reason}"),
        }
    }
}

fn error_word(error: impl Word) -> String {
    error.word()
}

/// The detail of a session error, bounded and credential-free (the protocol machines already removed the
/// credential from it).
fn detail_of(error: &SessionError) -> String {
    match error {
        SessionError::AuthFailed(detail) | SessionError::Protocol(detail) | SessionError::Transport(detail) => sanitize(detail, &[]),
        SessionError::Closed(reason) => (*reason).to_string(),
    }
}

/// A duration for a log or a status line.
#[allow(dead_code)]
fn millis(duration: Duration) -> u64 {
    duration.as_millis() as u64
}

#[allow(dead_code)]
fn unused_store_error(error: kv::Error) -> String {
    error_text(error)
}
