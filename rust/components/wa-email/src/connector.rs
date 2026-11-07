//! The connector's decisions, between the protocol machines and the guest's transport.
//!
//! Everything here is transport-agnostic: [`sync_round`] drives an [`Imap`] over any [`Link`], parses
//! each fetched message (`mime`), writes it into the index (`wa_email_index`) and reports what happened;
//! [`deliver`] drives an [`Smtp`] submission the same way. The guest implements [`Link`] over
//! `wa:email/transport` (TLS in the kernel) and gets its store from `wa:kernel/kv`; the tests implement
//! [`Link`] over an in-process server and its store in memory. There is no second code path: the fake
//! servers in the tests answer the same commands a real server does.
use std::future::Future;

use wa_email_index::{keys, Record, Store, SyncState};
use wa_email_outbox::Secret;

use crate::imap::{Event as ImapEvent, Imap, Step as ImapStep};
use crate::mime;
use crate::smtp::{Event as SmtpEvent, Smtp, Step as SmtpStep};

/// The transport failed: a write or a read the driver could not complete.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LinkError(pub String);

/// A byte stream to a server, as an async guest sees one. `read` resolves with the next bytes; an empty
/// list means the peer closed (the kernel's rule), and a pending `read` is what a parked guest task is
/// waiting on.
pub trait Link {
    fn read(&mut self, max: u32) -> impl Future<Output = Result<Vec<u8>, LinkError>>;
    fn write(&mut self, bytes: &[u8]) -> impl Future<Output = Result<(), LinkError>>;
    fn close(&mut self) -> impl Future<Output = ()>;
}

/// The cap on one read: an IMAP response or an SMTP reply line, well inside the kernel's frame bound.
pub const READ_CHUNK: u32 = 64 * 1024;

/// What one sync round did.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SyncReport {
    pub uid_validity: u32,
    /// UIDs the server offered this round.
    pub fetched: u32,
    /// Records newly written to the index (a refetch is not new).
    pub indexed: u32,
    /// Messages whose body was over the session's bound and were not indexed.
    pub skipped: u32,
    /// The UID floor for the next round.
    pub last_uid: u32,
}

/// Why a session ended without finishing its round.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SessionError {
    /// The server refused the credential. The detail is the server's line, credential removed.
    AuthFailed(String),
    /// The protocol broke (an unexpected answer, an unreadable fetch).
    Protocol(String),
    /// The connection ended (peer close, EOF, `* BYE`).
    Closed(&'static str),
    /// The transport itself failed (a refused dial, a broken TLS session).
    Transport(String),
}

impl SessionError {
    /// The stable word a log line and a status answer use.
    pub fn code(&self) -> &'static str {
        match self {
            SessionError::AuthFailed(_) => "email_auth_failed",
            SessionError::Protocol(_) => "email_protocol_error",
            SessionError::Closed(_) => "email_connection_closed",
            SessionError::Transport(_) => "email_transport_error",
        }
    }

    /// True when the same connection could work if it were made again (a drop), false when the answer
    /// is permanent until an operator acts (a refused credential).
    pub fn retryable(&self) -> bool {
        !matches!(self, SessionError::AuthFailed(_))
    }
}

/// Run one IMAP session round: log in, select, fetch what is above `last_uid`, index it.
///
/// `on_record` is called once per newly indexed record, in UID order, with the record the store now
/// holds: the guest turns those into `email.received` events, and the tests collect them.
pub async fn sync_round<L: Link, S: Store, F: FnMut(&Record)>(
    imap: &mut Imap,
    link: &mut L,
    store: &mut S,
    mailbox: &str,
    max_text: usize,
    received_ms: i64,
    mut on_record: F,
) -> Result<SyncReport, SessionError> {
    let mut report = SyncReport::default();
    loop {
        match imap.step() {
            ImapStep::Write(bytes) => {
                if let Err(error) = link.write(&bytes).await {
                    let _ = imap.abandon("transport");
                    return Err(SessionError::Transport(error.0));
                }
            }
            ImapStep::Wait => {
                let bytes = match link.read(READ_CHUNK).await {
                    Ok(bytes) => bytes,
                    Err(error) => {
                        let _ = imap.abandon("transport");
                        return Err(SessionError::Transport(error.0));
                    }
                };
                // The kernel's transport says an empty list is end of stream.
                let events = if bytes.is_empty() { imap.on_eof() } else { imap.on_bytes(&bytes) };
                for event in events {
                    match event {
                        ImapEvent::Selected { uid_validity, .. } => report.uid_validity = uid_validity,
                        ImapEvent::Message(fetched) => {
                            report.fetched += 1;
                            let parsed = mime::parse(&fetched.body, max_text);
                            let (record, attachment_bytes) =
                                parsed.into_record(mailbox, fetched.uid, report.uid_validity, fetched.internal_date_ms.unwrap_or(received_ms), fetched.flags, max_text);
                            match wa_email_index::index_record(store, &record, &attachment_bytes) {
                                Ok(indexed) => {
                                    if indexed.new {
                                        report.indexed += 1;
                                        on_record(&record);
                                    }
                                }
                                Err(detail) => return Err(SessionError::Protocol(detail)),
                            }
                        }
                        ImapEvent::Skipped { .. } => report.skipped += 1,
                        ImapEvent::AuthFailed { answer } => return Err(SessionError::AuthFailed(answer)),
                        ImapEvent::Protocol { detail } => return Err(SessionError::Protocol(detail)),
                        ImapEvent::Closed { reason } => return Err(SessionError::Closed(reason)),
                    }
                }
            }
            ImapStep::RoundDone => {
                // The session's own counters are the report: `fetched` counts what the server offered
                // this round, `indexed` what was new to the index (`skipped` what was too big to keep).
                report.fetched = imap.fetched();
                report.last_uid = imap.last_uid();
                return Ok(report);
            }
        }
    }
}

/// The sync state a mailbox session stores: the UID floor and the generation it belongs to.
pub fn sync_state(mailbox: &str, report: &SyncReport, now_ms: i64) -> SyncState {
    SyncState { mailbox: keys::name(mailbox), uid_validity: report.uid_validity, last_uid: report.last_uid, synced_ms: now_ms }
}

/// The UID floor to start from, from the state the last session stored. A UIDVALIDITY change means every
/// UID the index knows is about a different mailbox, so the floor goes back to zero (and the keys, which
/// carry the generation, keep the old generation's records apart instead of overwriting them).
pub fn resume_floor(state: Option<&[u8]>, uid_validity: u32) -> u32 {
    match state.and_then(sync_state_from_bytes) {
        Some(state) if state.uid_validity == uid_validity => state.last_uid,
        _ => 0,
    }
}

/// Where a mailbox session's state lives in kv.
pub fn sync_state_key(state: &SyncState) -> Vec<u8> {
    keys::state(&state.mailbox, state.uid_validity)
}

/// The bytes stored there.
pub fn encode_state(state: &SyncState) -> Vec<u8> {
    serde_json::to_vec(state).unwrap_or_default()
}

fn sync_state_from_bytes(bytes: &[u8]) -> Option<SyncState> {
    serde_json::from_slice(bytes).ok()
}

/// What one submission did.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SendOutcome {
    Sent { message_id: String, recipients: usize },
    Refused { code: &'static str, detail: String, retryable: bool },
}

impl SendOutcome {
    /// The reason the queue stores for a failed job: a stable word plus the server's bounded line.
    pub fn reason(&self) -> String {
        match self {
            SendOutcome::Sent { .. } => "sent".to_string(),
            SendOutcome::Refused { code, detail, .. } => format!("{code}: {detail}"),
        }
    }
}

/// Drive one SMTP submission to its end.
pub async fn deliver<L: Link>(smtp: &mut Smtp, link: &mut L) -> Result<SendOutcome, SessionError> {
    loop {
        match smtp.step() {
            SmtpStep::Write(bytes) => {
                if let Err(error) = link.write(&bytes).await {
                    let _ = smtp.abandon("transport");
                    return Err(SessionError::Transport(error.0));
                }
            }
            SmtpStep::Wait => {
                let bytes = match link.read(READ_CHUNK).await {
                    Ok(bytes) => bytes,
                    Err(error) => {
                        let _ = smtp.abandon("transport");
                        return Err(SessionError::Transport(error.0));
                    }
                };
                let events = if bytes.is_empty() { smtp.on_eof() } else { smtp.on_bytes(&bytes) };
                match events.into_iter().next() {
                    Some(SmtpEvent::Sent { message_id, recipients }) => return Ok(SendOutcome::Sent { message_id, recipients }),
                    Some(SmtpEvent::Refused { code, detail, retryable }) => return Ok(SendOutcome::Refused { code, detail, retryable }),
                    Some(SmtpEvent::Closed { reason }) => return Err(SessionError::Closed(reason)),
                    // One reply produces one event; an empty list means the answer is still partial and the
                    // next read continues the dialog.
                    None => {}
                }
            }
            SmtpStep::Done => return Err(SessionError::Protocol("the submission ended without an answer".into())),
        }
    }
}

/// Answer one query from the index, in the shape both the tool and the component use.
pub fn answer_query<S: Store>(store: &S, request: &wa_email_index::Request) -> Result<wa_email_index::Answer, String> {
    if let Err(refusal) = request.validate() {
        return Ok(wa_email_index::refusal(&refusal));
    }
    match request.op {
        wa_email_index::Op::Search => wa_email_index::search(store, request),
        wa_email_index::Op::Read => wa_email_index::read(store, request),
        wa_email_index::Op::Media => wa_email_index::media(store, request),
    }
}

/// The credential rules: a value the connector will accept at all. A CR/LF would end an IMAP `LOGIN`
/// argument or an SMTP `AUTH LOGIN` line early, so it is refused before a byte is sent - and the
/// refusal never quotes the value.
pub fn check_credential(password: &Secret) -> Result<(), &'static str> {
    if password.is_empty() {
        return Err("email_credential_empty");
    }
    if password.expose().chars().any(|c| c.is_control()) {
        return Err("email_credential_invalid");
    }
    if password.expose().chars().count() > 512 {
        return Err("email_credential_invalid");
    }
    Ok(())
}

#[cfg(test)]
mod tests;
