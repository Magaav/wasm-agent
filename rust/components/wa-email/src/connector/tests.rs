//! The connector's loop, measured end to end against in-process servers: receive -> indexed ->
//! searchable, send -> delivered -> status done, a dropped IMAP connection -> reconnect without
//! duplicates, and a refused credential -> a clear error that carries no secret. No port, no thread, no
//! real mailbox: the fake servers answer the same commands a real server does, and the store is
//! `wa_email_index::MemoryStore` - the same index the guest materialises from kv.
use futures::executor::block_on;
use wa_email_index::{MemoryStore, Request as Query};
use wa_email_outbox::{done_result, status, Mailbox, Request as OutboxRequest, Secret};

use super::*;
use crate::compose::compose;
use crate::imap::tests::{FakeImap, Loopback};
use crate::smtp::Smtp;
use crate::smtp::tests::{FakeSmtp, SmtpLoopback};

/// An [`Imap`] session over the in-process server.
struct ImapLink {
    inner: Loopback,
}

impl Link for ImapLink {
    async fn read(&mut self, _max: u32) -> Result<Vec<u8>, LinkError> {
        // An empty list is end of stream, which is exactly what a fake that has nothing to say means.
        Ok(self.inner.read().unwrap_or_default())
    }

    async fn write(&mut self, bytes: &[u8]) -> Result<(), LinkError> {
        self.inner.write(bytes);
        Ok(())
    }

    async fn close(&mut self) {}
}

/// An [`Smtp`] submission over the in-process server.
struct SmtpLink {
    inner: SmtpLoopback,
}

impl Link for SmtpLink {
    async fn read(&mut self, _max: u32) -> Result<Vec<u8>, LinkError> {
        Ok(self.inner.inbound.pop_front().unwrap_or_default())
    }

    async fn write(&mut self, bytes: &[u8]) -> Result<(), LinkError> {
        if self.inner.closed {
            return Ok(());
        }
        match self.inner.server.on_bytes(bytes) {
            Some(answer) => {
                if !answer.is_empty() {
                    self.inner.inbound.push_back(answer)
                }
            }
            None => self.inner.closed = true,
        }
        Ok(())
    }

    async fn close(&mut self) {}
}

fn message(uid: u32, subject: &str, body: &str) -> String {
    format!(
        "From: Ana Silva <ana@example.com>\r\nTo: me@example.com\r\nSubject: {subject}\r\nMessage-ID: <{uid}@example.com>\r\nDate: Fri, 06 Nov 2026 10:00:00 +0000\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n{body}\r\n"
    )
}

/// One full round against a fresh fake, with the records it indexed.
fn round(server: FakeImap, store: &mut MemoryStore) -> (Result<SyncReport, SessionError>, Vec<wa_email_index::Record>) {
    let mut link = ImapLink { inner: Loopback::new(server) };
    let mut imap = Imap::new("INBOX", "me@example.com", Secret::new("s3cret"));
    let mut records = Vec::new();
    let result = block_on(sync_round(&mut imap, &mut link, store, "INBOX", wa_email_index::MAX_TEXT, 1_700_000_000_000, |record| {
        records.push(record.clone());
    }));
    (result, records)
}

#[test]
fn a_received_message_is_indexed_and_found_by_an_accent_folded_search() {
    let mut server = FakeImap::new("me@example.com", "s3cret");
    server.messages.push((1, message(1, "Relatório mensal", "Segue o relatório de Ação em anexo.").into_bytes(), false));
    let mut store = MemoryStore::default();
    let (result, records) = round(server, &mut store);
    let report: SyncReport = result.expect("a completed round");
    assert_eq!(report.uid_validity, 7);
    assert_eq!((report.fetched, report.indexed, report.skipped), (1, 1, 0));
    assert_eq!(report.last_uid, 1);
    assert_eq!(records.len(), 1, "the round hands the caller the new record for the bus event");
    assert_eq!(records[0].subject, "Relatório mensal");
    assert_eq!(store.len(), 2, "one record plus its message-id pointer");

    // Searchable the way the tool will ask: unaccented, lowercase.
    let answer = answer_query(&store, &Query::search().with_q("acao")).expect("an answer");
    assert_eq!(answer["ok"], true);
    assert_eq!(answer["matched"], 1);
    assert_eq!(answer["hits"][0]["subject"], "Relatório mensal");
    assert_eq!(answer["hits"][0]["uid"], 1);
    // And readable as one message, with the body the server sent.
    let mut read = Query::read(None);
    read.uid = Some(1);
    let one = answer_query(&store, &read).expect("an answer");
    assert_eq!(one["found"], true);
    assert!(one["message"]["text"].as_str().unwrap().contains("Ação"));
    // The bus fact for the same record is metadata only: the topic is the one the manifest grants.
    let (topic, schema, version, payload) = wa_email_index::received_event(&records[0]);
    assert_eq!((topic.as_str(), schema.as_str(), version), ("email.received", "wa:email/received", 1));
    assert_eq!(payload["uid"], 1);
    assert!(!serde_json::to_string(&payload).unwrap().contains("Ação em anexo"), "no body text in the event");
}

#[test]
fn a_send_is_delivered_to_the_fake_and_its_status_says_done() {
    let from = Mailbox::parse("me@example.com").expect("a valid sender");
    let request = OutboxRequest {
        to: vec!["ana@example.com".into()],
        cc: Vec::new(),
        subject: "Relatório".into(),
        body: "Segue o relatório.".into(),
        in_reply_to: None,
        attachments: Vec::new(),
    };
    let verified = request.validate().expect("a valid request");
    let dedupe = request.dedupe_key();
    let composed = compose(&from, &verified, &dedupe, 1_793_959_200_000);
    let mut smtp = Smtp::new("client.example.com", "me@example.com", Secret::new("s3cret"), &from, &verified, &composed);
    let mut link = SmtpLink { inner: SmtpLoopback::new(FakeSmtp::new("me@example.com", "s3cret")) };
    let outcome = block_on(deliver(&mut smtp, &mut link)).expect("a completed submission");
    match &outcome {
        SendOutcome::Sent { message_id, recipients } => {
            assert_eq!(message_id, &composed.message_id);
            assert_eq!(*recipients, 1);
        }
        other => panic!("expected a delivery, got {other:?}"),
    }
    // The fake received exactly the composed message, and the connector's own audit target names the
    // recipient by digest, never by address.
    assert_eq!(link.inner.server.data, composed.bytes);
    let target = wa_email_outbox::audit_target(&verified.recipients());
    assert!(target.starts_with("email:1rcpt:"));
    assert!(!target.contains('@'));
    // `email_send_status` reads the settled job back: done, with the message id the server saw.
    let answer = status(42, "done", 1, Some(&done_result(&composed.message_id)), None);
    assert_eq!(answer["state"], "done");
    assert_eq!(answer["delivered"], true);
    assert_eq!(answer["message_id"], composed.message_id);
    assert_eq!(outcome.reason(), "sent");
}

#[test]
fn a_dropped_imap_connection_reconnects_and_does_not_index_a_message_twice() {
    let mut store = MemoryStore::default();
    // A server that serves one message and then drops the connection, mid-round.
    let mut dropping = FakeImap::new("me@example.com", "s3cret");
    dropping.messages.push((1, message(1, "primeira", "primeira mensagem").into_bytes(), false));
    dropping.messages.push((2, message(2, "segunda", "segunda mensagem").into_bytes(), false));
    dropping.close_after_fetch = Some(1);
    let (result, _) = round(dropping, &mut store);
    let error = result.expect_err("a dropped connection is an error");
    assert_eq!(error.code(), "email_connection_closed");
    assert!(error.retryable(), "a drop is worth another connection");
    assert_eq!(store.scan_bounded(b"r/", 100).unwrap().len(), 1, "what arrived before the drop was indexed");

    // The backoff the loop applies before trying again.
    let mut backoff = crate::reconnect::Backoff::default();
    assert_eq!(backoff.failure(1_000), 1_000);

    // The sync state the first session stored: the floor a resumed session keeps.
    let state = sync_state("INBOX", &SyncReport { uid_validity: 7, fetched: 1, indexed: 1, skipped: 0, last_uid: 1 }, 1_000);
    assert_eq!(resume_floor(Some(&encode_state(&state)), 7), 1);

    // The next connection: the same mailbox, still holding both messages (a server does not apply our
    // index), so the resumed round must not duplicate the first one.
    let mut healthy = FakeImap::new("me@example.com", "s3cret");
    healthy.messages.push((1, message(1, "primeira", "primeira mensagem").into_bytes(), false));
    healthy.messages.push((2, message(2, "segunda", "segunda mensagem").into_bytes(), false));
    let mut link = ImapLink { inner: Loopback::new(healthy) };
    let mut imap = Imap::new("INBOX", "me@example.com", Secret::new("s3cret"));
    let mut records = Vec::new();
    let report = block_on(sync_round(&mut imap, &mut link, &mut store, "INBOX", wa_email_index::MAX_TEXT, 1_700_000_000_000, |record| records.push(record.clone())))
        .expect("the reconnect round");
    // A fresh connection re-reads the mailbox from UID 1 unless the floor is resumed; the index's own
    // UID rule is what makes that harmless: UID 1 is already there, so it is not indexed twice.
    assert_eq!(store.scan_bounded(b"r/", 100).unwrap().len(), 2, "two messages, no duplicates: {}", store.keys().join(", "));
    assert!(report.indexed <= 1, "only a message that is new is indexed: {report:?}");
    assert!(records.iter().all(|record| record.uid == 2), "the duplicate delivery is not re-announced");
    assert_eq!(report.last_uid, 2);
    // Searching finds each message exactly once.
    let answer = answer_query(&store, &Query::search().with_q("mensagem")).expect("an answer");
    assert_eq!(answer["matched"], 2);
}

#[test]
fn a_refused_credential_is_a_clear_error_and_no_line_carries_the_password() {
    let mut server = FakeImap::new("me@example.com", "the-real-one");
    server.fail_login = true;
    server.messages.push((1, message(1, "x", "y").into_bytes(), false));
    let mut link = ImapLink { inner: Loopback::new(server) };
    let password = Secret::new("wrong-password-123");
    let mut imap = Imap::new("INBOX", "me@example.com", password.clone());
    let mut store = MemoryStore::default();
    let error = block_on(sync_round(&mut imap, &mut link, &mut store, "INBOX", wa_email_index::MAX_TEXT, 0, |_| {})).expect_err("a refused login");
    assert_eq!(error.code(), "email_auth_failed");
    assert!(!error.retryable(), "the same credential will not start working");
    let detail = match &error {
        SessionError::AuthFailed(detail) => detail.clone(),
        other => panic!("expected an auth failure, got {other:?}"),
    };
    assert!(detail.contains("AUTHENTICATIONFAILED"), "{detail}");
    assert!(!detail.contains(password.expose()), "the server's answer is logged with the credential removed: {detail}");
    // Nothing was indexed, and nothing a caller logs holds the password either.
    assert!(store.is_empty());
    let line = crate::telemetry::Line::new("auth_failed").word("code", error.code()).word("detail", &detail).build();
    assert!(!line.contains(password.expose()), "{line}");
    let quiet = crate::telemetry::sanitize(&detail, &[password.expose()]);
    assert!(!quiet.contains(password.expose()));
    // A status answer for the settled job carries the word, not the server's line.
    let settled = status(9, "dead", 3, None, Some(error.code()));
    assert_eq!(settled["reason"], "email_auth_failed");
}

#[test]
fn a_query_is_answered_from_the_index_and_a_bad_one_is_refused() {
    let mut store = MemoryStore::default();
    let message_record = wa_email_index::Record {
        mailbox: "INBOX".into(),
        uid: 1,
        uid_validity: 7,
        message_id: Some("<1@example.com>".into()),
        from: wa_email_index::Address::new(Some("Ana"), "ana@example.com"),
        to: vec![wa_email_index::Address::new(None, "me@example.com")],
        cc: Vec::new(),
        subject: "Fatura".into(),
        received_ms: 1_700_000_000_000,
        sent_ms: None,
        in_reply_to: None,
        snippet: "segue".into(),
        text: "segue a fatura".into(),
        text_truncated: false,
        attachments: vec![wa_email_index::AttachmentMeta {
            filename: "fatura.txt".into(),
            mime: "text/plain".into(),
            size: 9,
            sha256: wa_email_index::hash16(b"fatura 42"),
            part: "2".into(),
            stored: true,
        }],
        flags: vec!["\\Seen".into()],
    };
    let bytes = b"fatura 42".to_vec();
    wa_email_index::index_record(&mut store, &message_record, &[bytes]).unwrap();
    // search / read / media all go through one dispatcher.
    assert_eq!(answer_query(&store, &Query::search().with_q("fatura")).unwrap()["matched"], 1);
    let mut read = Query::read(Some("inbox"));
    read.uid = Some(1);
    assert_eq!(answer_query(&store, &read).unwrap()["message"]["subject"], "Fatura");
    assert_eq!(answer_query(&store, &Query::media(1, None)).unwrap()["attachments"][0]["downloadable"], true);
    // A request that cannot be a question is a refusal with a word, exactly what the tool answers.
    let bad = Query::search();
    let answer = answer_query(&store, &bad).expect("a refusal is an answer, not an error");
    assert_eq!(answer["ok"], false);
    assert_eq!(answer["error"], "email_empty_query");
    // A message the index does not have is an answer, not a failure.
    let mut missing = Query::read(None);
    missing.uid = Some(9);
    assert_eq!(answer_query(&store, &missing).unwrap()["found"], false);
}

#[test]
fn a_credential_that_could_break_a_protocol_line_is_refused_before_it_is_used() {
    assert_eq!(check_credential(&Secret::new("")), Err("email_credential_empty"));
    assert_eq!(check_credential(&Secret::new("a\r\nb")), Err("email_credential_invalid"));
    assert_eq!(check_credential(&Secret::new("a\u{0}b")), Err("email_credential_invalid"));
    assert_eq!(check_credential(&Secret::new("x".repeat(513))), Err("email_credential_invalid"));
    assert_eq!(check_credential(&Secret::new("a normal passphrase")), Ok(()));
}

#[test]
fn a_uidvalidity_change_starts_the_mailbox_over_instead_of_overwriting_the_old_generation() {
    let old = sync_state("INBOX", &SyncReport { uid_validity: 7, fetched: 2, indexed: 2, skipped: 0, last_uid: 2 }, 0);
    assert_eq!(resume_floor(Some(&encode_state(&old)), 7), 2, "the same generation resumes at its floor");
    assert_eq!(resume_floor(Some(&encode_state(&old)), 8), 0, "a new generation starts at zero");
    assert_eq!(resume_floor(None, 8), 0);
    // The keys carry the generation, so the old records are not overwritten by the new UID space.
    assert_ne!(wa_email_index::keys::record("INBOX", 7, 1), wa_email_index::keys::record("INBOX", 8, 1));
    assert_eq!(sync_state_key(&old), b"s/INBOX/0000000007".to_vec());
}
