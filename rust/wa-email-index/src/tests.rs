//! The index's rules, measured in memory: keys, dedupe, folding, ranking, pagination, bounding and
//! the bus fact. No host, no kv, no wasm - the same functions the component's guest loop calls.
use super::*;

use crate::MemoryStore;

fn address(name: Option<&str>, addr: &str) -> Address {
    Address::new(name, addr)
}

fn record(uid: u32, subject: &str, text: &str) -> Record {
    Record {
        mailbox: "INBOX".into(),
        uid,
        uid_validity: 7,
        message_id: Some(format!("<{uid}@example.com>")),
        from: address(Some("Ana Silva"), "ana@example.com"),
        to: vec![address(None, "me@example.com")],
        cc: Vec::new(),
        subject: subject.to_string(),
        received_ms: 1_700_000_000_000 + uid as i64,
        sent_ms: None,
        in_reply_to: None,
        snippet: text.chars().take(MAX_SNIPPET).collect::<String>().replace('\n', " "),
        text: text.to_string(),
        text_truncated: false,
        attachments: Vec::new(),
        flags: vec!["\\Seen".into()],
    }
}

fn attachment(filename: &str, bytes: &[u8]) -> (AttachmentMeta, Vec<u8>) {
    let meta = AttachmentMeta {
        filename: filename.into(),
        mime: "text/plain".into(),
        size: bytes.len() as u64,
        sha256: hash16(bytes) + &hash16(&[bytes.len() as u8]),
        part: "2".into(),
        stored: true,
    };
    (meta, bytes.to_vec())
}

#[test]
fn keys_sort_by_mailbox_generation_and_uid_and_never_carry_a_separator_they_did_not_mint() {
    assert_eq!(keys::record("inbox", 7, 9), b"r/INBOX/0000000007/0000000009".to_vec());
    assert_eq!(keys::record("inbox", 7, 10), b"r/INBOX/0000000007/0000000010".to_vec());
    // Padded, so `scan` order is UID order and not lexicographic-by-accident.
    assert!(keys::record("INBOX", 7, 9) < keys::record("INBOX", 7, 10));
    assert!(keys::record("INBOX", 7, 99) < keys::record("INBOX", 8, 1), "a new generation sorts after the old one");
    // A mailbox name with the key separator in it cannot forge another mailbox's prefix.
    assert_eq!(keys::name("a/b c"), "A_B_C");
    assert_eq!(keys::name(""), "INBOX");
    assert_eq!(keys::state("inbox", 7), b"s/INBOX/0000000007".to_vec());
    assert_eq!(keys::media("abc"), b"b/abc".to_vec());
    assert!(keys::message_id("<X@Example.com>", "inbox", 3).starts_with(b"m/"));
    // The message-id digest is case-insensitive: the same id twice is one pointer prefix.
    let upper = keys::message_id("<X@Example.com>", "INBOX", 3);
    let lower = keys::message_id("<x@example.com>", "INBOX", 3);
    assert_eq!(upper, lower);
}

#[test]
fn a_fetched_message_is_indexed_once_and_a_refetch_is_not_a_new_message() {
    let mut store = MemoryStore::default();
    let message = record(1, "Relatório mensal", "Segue o relatório em anexo.");
    let first = index_record(&mut store, &message, &[]).unwrap();
    assert!(first.new);
    // The reconnect case: the same UID arrives again after a dropped connection.
    let second = index_record(&mut store, &message, &[]).unwrap();
    assert!(!second.new, "a refetch must not duplicate the index");
    assert_eq!(store.scan_bounded(b"r/", 100).unwrap().len(), 1);
    assert_eq!(store.scan_bounded(b"m/", 100).unwrap().len(), 1, "one message-id pointer");
    // The stored bytes are the record, readable back.
    let stored = store.get(&message.key()).unwrap();
    assert_eq!(Record::decode(&stored).unwrap(), message);
    // A different UID in the same mailbox is a different message.
    let other = record(2, "Relatório mensal", "outro");
    assert!(index_record(&mut store, &other, &[]).unwrap().new);
    assert_eq!(store.scan_bounded(b"r/", 100).unwrap().len(), 2);
}

#[test]
fn attachments_are_carried_into_kv_when_they_fit_and_are_metadata_only_when_they_do_not() {
    let mut store = MemoryStore::default();
    let mut with = record(1, "relatorio", "segue");
    let (small, small_bytes) = attachment("relatorio.txt", b"acao\n");
    let big_bytes = vec![7u8; keys::MAX_MEDIA + 1];
    let mut big = small.clone();
    big.filename = "video.bin".into();
    big.size = big_bytes.len() as u64;
    big.sha256 = "f".repeat(64);
    with.attachments = vec![small, big];
    let indexed = index_record(&mut store, &with, &[small_bytes.clone(), big_bytes.clone()]).unwrap();
    assert_eq!(indexed.media_bytes, small_bytes.len(), "the big one is not carried into kv");
    assert!(store.get(&keys::media(&with.attachments[0].sha256)).is_some());
    assert!(store.get(&keys::media(&with.attachments[1].sha256)).is_none());

    let answer = media(&store, &Request::media(1, None)).unwrap();
    assert_eq!(answer["found"], true);
    assert_eq!(answer["attachments"][0]["filename"], "relatorio.txt");
    assert_eq!(answer["attachments"][0]["downloadable"], true);
    assert!(answer["attachments"][0]["handle"].as_str().unwrap().starts_with("email-media:"));
    assert_eq!(answer["attachments"][1]["downloadable"], false, "a big attachment is refused by name, not faked");
    // The bytes never appear in the media answer: they travel as progress chunks.
    assert!(!serde_json::to_string(&answer).unwrap().contains("acao"));
    // A message that is not in the index says so instead of answering with a neighbour.
    assert_eq!(media(&store, &Request::media(99, None)).unwrap()["found"], false);
}

#[test]
fn search_folds_accents_and_matches_every_term() {
    let mut store = MemoryStore::default();
    index_record(&mut store, &record(1, "Relatório mensal de ação", "Segue o relatório de Ação em anexo."), &[]).unwrap();
    index_record(&mut store, &record(2, "Almoço", "Vamos almoçar na sexta?"), &[]).unwrap();
    let answer = search(&store, &Request::search().with_q("acao")).unwrap();
    assert_eq!(answer["ok"], true);
    assert_eq!(answer["matched"], 1, "the accented subject is found by the unaccented word");
    assert_eq!(answer["hits"][0]["uid"], 1);
    // Case and accents both fold.
    assert_eq!(search(&store, &Request::search().with_q("RELATORIO")).unwrap()["matched"], 1);
    assert_eq!(search(&store, &Request::search().with_q("almocar")).unwrap()["matched"], 1);
    // Every term must match, in any order.
    assert_eq!(search(&store, &Request::search().with_q("acao relatorio")).unwrap()["matched"], 1);
    assert_eq!(search(&store, &Request::search().with_q("acao almoco")).unwrap()["matched"], 0);
    // The sender's display name is searchable too, so "ana" finds her mail.
    assert_eq!(search(&store, &Request::search().with_q("ana")).unwrap()["matched"], 2);
}

#[test]
fn the_best_match_comes_first_and_the_answer_is_bounded() {
    let mut store = MemoryStore::default();
    // The phrase in the subject beats the phrase only in the body.
    index_record(&mut store, &record(1, "Nota fiscal", "o valor do imposto mudou"), &[]).unwrap();
    index_record(&mut store, &record(2, "Re: orçamento", "sobre o orçamento aprovado"), &[]).unwrap();
    index_record(&mut store, &record(3, "Reunião", "falamos do orçamento ontem"), &[]).unwrap();
    let answer = search(&store, &Request::search().with_q("orcamento")).unwrap();
    assert_eq!(answer["matched"], 2);
    assert_eq!(answer["hits"][0]["uid"], 2, "the subject hit ranks first");
    // A limit smaller than the matches says so instead of silently cutting.
    let limited = search(&store, &Request::search().with_q("orcamento").with_limit(1)).unwrap();
    assert_eq!(limited["returned"], 1);
    assert_eq!(limited["matched"], 2);
    assert_eq!(limited["truncated"], true);
}

/// `Request` needs a small builder for the tests (a field-by-field struct literal in every case is
/// noise that hides which filter the test is about).
impl Request {
    fn with_limit(mut self, limit: u32) -> Request {
        self.limit = Some(limit);
        self
    }

        fn since(mut self, since: i64) -> Request {
        self.since = Some(since);
        self
    }

    fn until(mut self, until: i64) -> Request {
        self.until = Some(until);
        self
    }

    fn from(mut self, from: &str) -> Request {
        self.from = Some(from.to_string());
        self
    }

    fn subject(mut self, subject: &str) -> Request {
        self.subject = Some(subject.to_string());
        self
    }

    fn mailbox(mut self, mailbox: &str) -> Request {
        self.mailbox = Some(mailbox.to_string());
        self
    }

    fn has_attachment(mut self, want: bool) -> Request {
        self.has_attachment = Some(want);
        self
    }
}

#[test]
fn the_filters_narrow_by_sender_subject_time_window_mailbox_and_attachment() {
    let mut store = MemoryStore::default();
    let mut with = record(1, "Fatura de março", "segue a fatura");
    let (meta, bytes) = attachment("fatura.pdf", b"%PDF-1.4 cat");
    with.attachments = vec![meta];
    index_record(&mut store, &with, &[bytes]).unwrap();
    let mut second = record(2, "Fatura de abril", "segue a fatura");
    second.from = address(Some("Bruno"), "bruno@example.org");
    second.received_ms = with.received_ms + 86_400_000;
    index_record(&mut store, &second, &[]).unwrap();

    assert_eq!(search(&store, &Request::search().from("bruno")).unwrap()["matched"], 1);
    assert_eq!(search(&store, &Request::search().from("ANA")).unwrap()["matched"], 1);
    assert_eq!(search(&store, &Request::search().subject("abril")).unwrap()["matched"], 1);
    assert_eq!(search(&store, &Request::search().has_attachment(true)).unwrap()["matched"], 1);
    assert_eq!(search(&store, &Request::search().has_attachment(false)).unwrap()["matched"], 1);
    let window = Request::search().since(with.received_ms).until(with.received_ms + 1000);
    assert_eq!(search(&store, &window).unwrap()["matched"], 1);
    // A filter-only query has no text to rank: it answers by recency, newest first.
    let all = search(&store, &Request::search().mailbox("inbox")).unwrap();
    assert_eq!(all["matched"], 2);
    assert_eq!(all["hits"][0]["uid"], 2);
    // A mailbox nobody fetched into is empty, not an error.
    assert_eq!(search(&store, &Request::search().mailbox("Sent")).unwrap()["matched"], 0);
}

#[test]
fn a_big_answer_is_a_smaller_answer_with_truncated_set() {
    let mut store = MemoryStore::default();
    for uid in 1..=MAX_LIMIT {
        let mut big = record(uid, &format!("nota {uid}"), &"palavra ".repeat(MAX_TEXT / 8));
        big.text.truncate(MAX_TEXT);
        index_record(&mut store, &big, &[]).unwrap();
    }
    // A search hit is one line per message, so fifty hits fit the bound even with a full body
    // indexed; a read of fifty full messages does not, and that answer is bounded instead.
    let hits = search(&store, &Request::search().with_q("palavra").with_limit(MAX_LIMIT)).unwrap();
    assert!(serde_json::to_string(&hits).unwrap().len() <= RESULT_BOUND);
    assert_eq!(hits["returned"], MAX_LIMIT);
    let answer = read(&store, &Request::read(None).with_limit(MAX_LIMIT)).unwrap();
    let text = serde_json::to_string(&answer).unwrap();
    assert!(text.len() <= RESULT_BOUND, "an answer over the queue's result bound is not sent: {} bytes", text.len());
    assert_eq!(answer["truncated"], true);
    assert!(answer["messages"].as_array().unwrap().len() < MAX_LIMIT as usize, "trailing items are dropped, visibly");
    assert_eq!(answer["messages"][0]["uid"], MAX_LIMIT, "the newest message is still the first");
}

#[test]
fn a_mailbox_read_is_newest_first_and_paged_by_the_cursor_it_returns() {
    let mut store = MemoryStore::default();
    for uid in 1..=5 {
        index_record(&mut store, &record(uid, &format!("assunto {uid}"), "corpo"), &[]).unwrap();
    }
    let first = read(&store, &Request::read(None).with_limit(2)).unwrap();
    assert_eq!(first["count"], 2);
    assert_eq!(first["has_more"], true);
    assert_eq!(first["messages"][0]["uid"], 5, "newest first");
    let next = first["next_before"].as_u64().unwrap() as u32;
    let mut second = Request::read(None).with_limit(2);
    second.before = Some(next);
    let second = read(&store, &second).unwrap();
    assert_eq!(second["messages"][0]["uid"], 3);
    assert_eq!(second["has_more"], true);
    // The last page stops and says so.
    let mut third = Request::read(None).with_limit(2);
    third.before = second["next_before"].as_u64().map(|uid| uid as u32);
    let third = read(&store, &third).unwrap();
    assert_eq!(third["messages"][0]["uid"], 1);
    assert_eq!(third["has_more"], false);
    assert!(third["next_before"].is_null());
    // One message by UID, and a UID the index does not have is an answer, not an error.
    let mut one = Request::read(None);
    one.uid = Some(4);
    assert_eq!(read(&store, &one).unwrap()["message"]["uid"], 4);
    one.uid = Some(99);
    assert_eq!(read(&store, &one).unwrap()["found"], false);
    // The full message is what a reader needs: envelope, subject, text and flags.
    let full = &read(&store, &Request::read(None).with_limit(1)).unwrap()["messages"][0];
    assert_eq!(full["subject"], "assunto 5");
    assert_eq!(full["from"], "Ana Silva <ana@example.com>");
    assert_eq!(full["flags"][0], r"\Seen");
}

#[test]
fn the_received_event_carries_the_envelope_and_never_the_body() {
    let mut with = record(4, "Fatura de março", "Segue a fatura em anexo.\n\nObrigada, Ana");
    let (meta, _) = attachment("fatura.pdf", b"%PDF-1.4 cat");
    with.attachments = vec![meta];
    let (topic, schema, version, payload) = received_event(&with);
    assert_eq!(topic, "email.received");
    assert_eq!(schema, "wa:email/received");
    assert_eq!(version, 1);
    assert_eq!(payload["uid"], 4);
    assert_eq!(payload["subject"], "Fatura de março");
    assert_eq!(payload["from"], "Ana Silva <ana@example.com>");
    assert_eq!(payload["attachments"][0]["filename"], "fatura.pdf");
    let text = serde_json::to_string(&payload).unwrap();
    assert!(!text.contains("Obrigada"), "the body is not in the event: {text}");
    assert!(!text.contains("--boundary"), "no MIME structure leaks into the event");
    // Nothing body-shaped is in the event at all: no snippet, no text.
    assert!(payload.get("snippet").is_none());
    assert!(payload.get("text").is_none());
    assert_eq!(payload["has_text"], true);
}

#[test]
fn a_request_is_validated_before_it_becomes_a_job() {
    for (request, code) in [
        (Request::search(), "empty_query"),
        (Request::search().with_q("  "), "empty_query"),
        (Request::search().with_q(&"x".repeat(MAX_Q + 1)), "query_too_long"),
        (Request::search().with_q("a\u{0}b"), "bad_query"),
        (Request::search().with_q("ok").with_limit(0), "bad_limit"),
        (Request::search().with_q("ok").with_limit(MAX_LIMIT + 1), "bad_limit"),
        (Request::search().with_q("ok").since(10).until(1), "bad_window"),
        (Request::media(0, None), "uid_required"),
        (Request::search().from(&"x".repeat(201)), "filter_too_long"),
    ] {
        let refusal = request.validate().expect_err(&format!("{request:?}"));
        assert_eq!(refusal.code, code, "{request:?}");
        assert!(refusal.error().starts_with("email_"));
    }
    // The valid shapes, including a read with no narrowing at all (it reads the mailbox).
    assert!(Request::search().with_q("ok").validate().is_ok());
    assert!(Request::search().mailbox("inbox").validate().is_ok());
    assert!(Request::search().has_attachment(false).validate().is_ok());
    assert!(Request::read(None).validate().is_ok());
    let mut media = Request::media(3, Some("inbox"));
    assert!(media.validate().is_ok());
    media.uid = Some(3);
    // The dedupe key is the request itself: identical queries are one job.
    assert_eq!(Request::search().with_q("ok").dedupe_key(), Request::search().with_q("ok").dedupe_key());
    assert_ne!(Request::search().with_q("ok").dedupe_key(), Request::search().with_q("ok!").dedupe_key());
    // A payload round-trips through the queue.
    let request = Request::search().with_q("fatura").with_limit(5);
    assert_eq!(Request::decode(&request.encode()).unwrap().q.as_deref(), Some("fatura"));
    // `op` is required: a payload that does not say which question it asks is not read as a guess.
    assert!(Request::decode(b"{}").is_err());
    assert!(Request::decode(b"nope").is_err());
}

#[test]
fn the_refusal_answer_names_the_tool_word_and_the_reason() {
    let refused = refusal(&Refusal::new("empty_query", "pass words"));
    assert_eq!(refused["ok"], false);
    assert_eq!(refused["error"], "email_empty_query");
    assert_eq!(refused["detail"], "pass words");
    assert_eq!(answer(serde_json::json!({"hits": []}))["ok"], true);
}

#[test]
fn the_scan_budget_is_visible_in_the_answer_instead_of_being_a_silent_cut() {
    let mut store = MemoryStore::default();
    for uid in 1..=(MAX_SCAN as u32 + 5) {
        index_record(&mut store, &record(uid, "assunto", "corpo"), &[]).unwrap();
    }
    let answer = search(&store, &Request::search().with_q("corpo").with_limit(1)).unwrap();
    assert_eq!(answer["scanned"], MAX_SCAN);
    assert_eq!(answer["truncated"], true, "a bounded scan says it is bounded");
}

#[test]
fn folding_is_the_same_rule_on_both_sides_of_a_query() {
    assert_eq!(fold("AÇÃO Relatório"), "acao relatorio");
    assert_eq!(fold("ÀÉÎÕÜ Ç"), "aeiou c");
    assert_eq!(fold("ßæœ"), "sao");
    // A character the table does not know is left alone rather than mangled.
    assert_eq!(fold("日本語"), "日本語");
    assert_eq!(terms("  Ação   Relatório "), vec!["acao".to_string(), "relatorio".to_string()]);
    // Folding is idempotent, which is what lets the index store a folded haystack.
    assert_eq!(fold(&fold("Ação")), fold("Ação"));
}
