//! The past against a fake phone: a hand-built history sync in, records (and budgets) out.
//!
//! No test here touches WhatsApp, a socket or the host. The "history sync" is a `wa::HistorySync` built
//! by hand - the shape `whatsapp-rust` decodes out of the blob a `historySync` notification carries -
//! and the "host" is [`index::Memory`], the same kv contract without a store. The one test that needs
//! the real wire shape compresses the proto with zlib and drives it through
//! `LazyHistorySync::stream()`, which is exactly what the guest does with the event it receives.
use super::*;
use crate::index::Memory;
use crate::record::{self, Record};
use futures::executor::block_on;
use whatsapp_rust::waproto::buffa::MessageField;
use whatsapp_rust::waproto::whatsapp as wap;

const CHAT: &str = "120363000000000001@g.us";
const DM: &str = "5511999999999@lid";
const SENDER: &str = "5511888888888@s.whatsapp.net";
const OWN_PN: &str = "5511000000000@s.whatsapp.net";
const OWN_LID: &str = "72103978127547@lid";
/// Seconds, as the proto carries them, and *inside* the window: the drain measures a message's own
/// timestamp against the retention clock, so a fixture from 2023 would be (correctly) refused as old.
/// One thousand seconds before [`NOW`].
const BASE_TS: u64 = 1_759_999_000;

fn me() -> SelfJids {
    SelfJids { pn: OWN_PN.into(), lid: OWN_LID.into() }
}

/// One message as a history sync carries it: a `WebMessageInfo` inside a `HistorySyncMsg`.
fn entry(chat: &str, id: &str, ts: u64, body: &str, own: bool, participant: Option<&str>) -> wap::HistorySyncMsg {
    let message = wap::Message { conversation: Some(body.to_string()), ..Default::default() };
    let info = wap::WebMessageInfo {
        key: MessageField::some(wap::MessageKey {
            remote_jid: Some(chat.to_string()),
            from_me: Some(own),
            id: Some(id.to_string()),
            participant: participant.map(str::to_string),
        }),
        message: MessageField::some(message),
        message_timestamp: Some(ts),
        push_name: Some("Ana".into()),
        ..Default::default()
    };
    wap::HistorySyncMsg { message: MessageField::some(info), msg_order_id: None }
}

fn conversation(chat: &str, messages: Vec<wap::HistorySyncMsg>) -> wap::Conversation {
    wap::Conversation { id: chat.to_string(), messages, ..Default::default() }
}

fn text_chat(chat: &str, count: u64) -> wap::Conversation {
    let messages = (0..count).map(|i| entry(chat, &format!("H{i}"), BASE_TS + i, &format!("mensagem {i}"), false, None)).collect();
    conversation(chat, messages)
}

fn budget(per_sync: usize) -> Budget {
    Budget { per_sync, ..Budget::default() }
}

/// The same budget, keeping only `days` of the past: the one bound a drain has on age.
fn keeping(per_sync: usize, days: i64) -> Budget {
    Budget { per_sync, keep_ms: days * 86_400_000 }
}

/// When the tests say "now": the clock every backfilled record is measured against.
const NOW: i64 = 1_760_000_000_000;

/// One message `seconds` before [`NOW`], as the proto carries it (seconds).
fn seconds_ago(seconds: i64) -> u64 {
    (NOW / 1000 - seconds) as u64
}

/// Drain one conversation the way the guest does: a plan once, then the conversation.
fn drain(store: &Memory, chat: &wap::Conversation, budget: Budget) -> Progress {
    block_on(async {
        let mut plan = Plan::new(budget);
        drain_conversation(store, chat, &me(), &mut plan, 1_760_000_000_000).await
    })
}

/// The proto bytes, compressed exactly as a `historySync` notification carries them.
fn compressed(sync: &wap::HistorySync) -> Vec<u8> {
    let raw = whatsapp_rust::waproto::codec::history_sync_to_vec(sync);
    let mut out = vec![0u8; zlib_rs::compress_bound(raw.len())];
    let (compressed, code) = zlib_rs::compress_slice(&mut out, &raw, zlib_rs::DeflateConfig::default());
    assert_eq!(code, zlib_rs::ReturnCode::Ok, "compress: {code:?}");
    compressed.to_vec()
}

// ---- a blob becomes records ---------------------------------------------------------------

#[test]
fn a_history_blob_becomes_records_a_search_finds() {
    // The real path: the notification's compressed bytes, the library's streaming reader, one
    // conversation at a time, and the same record parser a live message goes through.
    let sync = wap::HistorySync {
        sync_type: wap::history_sync::HistorySyncType::INITIAL_BOOTSTRAP,
        conversations: vec![
            conversation(
                CHAT,
                vec![
                    entry(CHAT, "H1", BASE_TS, "segue o boleto de marco", false, Some(SENDER)),
                    entry(CHAT, "H2", BASE_TS + 60, "recebi, obrigado", true, None),
                ],
            ),
            conversation(DM, vec![entry(DM, "H3", BASE_TS + 120, "e o comprovante?", false, None)]),
        ],
        progress: Some(100),
        ..Default::default()
    };
    let blob = compressed(&sync);
    let lazy = whatsapp_rust::types::events::LazyHistorySync::new(
        bytes::Bytes::from(blob.clone()),
        whatsapp_rust::waproto::codec::history_sync_to_vec(&sync).len(),
        wap::history_sync::HistorySyncType::INITIAL_BOOTSTRAP as i32,
        None,
        Some(100),
    );
    let store = Memory::new();
    let progress = block_on(async {
        let mut plan = Plan::new(Budget::default());
        let mut total = Progress::default();
        let mut stream = lazy.stream();
        while let Some(conversation) = stream.next_conversation().expect("a decodable conversation") {
            total.merge(drain_conversation(&store, &conversation, &me(), &mut plan, 1_760_000_000_000).await);
        }
        total
    });
    assert_eq!((progress.conversations, progress.seen, progress.written), (2, 3, 3), "{}", progress.line());
    assert_eq!(progress.stopped, None);

    // Every record is in the index, marked as history, with the phone's timestamp and our own clock.
    let found = block_on(index::load(&store, CHAT, "H1")).unwrap().expect("the backfilled message");
    assert_eq!(found.kind, "text");
    assert_eq!(found.source, record::SOURCE_HISTORY);
    assert!(found.from_history());
    assert_eq!(found.ts, (BASE_TS as i64) * 1000);
    assert_eq!(found.received, 1_760_000_000_000);
    assert_eq!(found.sender, SENDER);

    // ...and a query answers with it, which is the point of the whole exercise: the index covers the
    // past, not only what arrived since start.
    let request = seam::Request { op: "search".into(), q: Some("boleto".into()), ..Default::default() }
        .validate()
        .expect("a valid search");
    let answer = block_on(index::search(&store, &request)).expect("a search");
    assert_eq!(answer["count"], 1, "{answer}");
    assert_eq!(answer["hits"][0]["id"], "H1");
    assert_eq!(answer["hits"][0]["source"], "history");

    // An own message is attributed to us, in the LID namespace the phone stores it under.
    let own = block_on(index::load(&store, CHAT, "H2")).unwrap().expect("our own message");
    assert!(own.own);
    assert_eq!(own.sender, OWN_LID);
    assert_eq!(own.sender_alt, OWN_PN);
}

#[test]
fn a_message_the_live_stream_already_indexed_keeps_its_own_row() {
    let store = Memory::new();
    // The live message, as `on_message` indexed it a moment before the sync re-delivered it.
    let live = Record {
        chat: CHAT.into(),
        id: "H1".into(),
        sender: SENDER.into(),
        ts: (BASE_TS as i64) * 1000,
        received: 1_759_999_999_000,
        kind: "text".into(),
        text: "segue o boleto de marco".into(),
        source: record::SOURCE_LIVE.into(),
        ..Record::default()
    };
    block_on(index::put(&store, &live)).expect("the live record");

    let chat = conversation(
        CHAT,
        vec![
            entry(CHAT, "H1", BASE_TS, "segue o boleto de marco", false, Some(SENDER)),
            entry(CHAT, "H0", BASE_TS - 60, "e antes disso?", false, Some(SENDER)),
        ],
    );
    let progress = drain(&store, &chat, Budget::default());
    assert_eq!((progress.seen, progress.written, progress.duplicate), (2, 1, 1), "{}", progress.line());

    // The row the live stream wrote is untouched: the dedupe is by id, and the first writer keeps it.
    let kept = block_on(index::load(&store, CHAT, "H1")).unwrap().expect("the live record");
    assert_eq!(kept.source, record::SOURCE_LIVE, "a sync never downgrades a live record");
    assert_eq!(kept.received, 1_759_999_999_000);
    // The older message is new, and it is marked as backfill.
    let older = block_on(index::load(&store, CHAT, "H0")).unwrap().expect("the older message");
    assert_eq!(older.source, record::SOURCE_HISTORY);
}

// ---- bounded ------------------------------------------------------------------------------

#[test]
fn a_message_older_than_the_window_is_not_backfilled() {
    // The one bound on how far back the past reaches: the same age the live index is pruned by. The
    // operator removed the 200-per-chat and 2000-total caps on 13/11, so this is what replaced them.
    let store = Memory::new();
    let chat = conversation(
        CHAT,
        vec![
            entry(CHAT, "OLD", seconds_ago(200 * 86_400), "doiscentos dias atras", false, Some(SENDER)),
            entry(CHAT, "KEPT", seconds_ago(179 * 86_400), "cento e setenta e nove dias", false, Some(SENDER)),
            entry(CHAT, "NEW", seconds_ago(60), "agora", false, Some(SENDER)),
        ],
    );
    let progress = drain(&store, &chat, keeping(1_000, 180));
    assert_eq!((progress.seen, progress.written, progress.too_old), (3, 2, 1), "{}", progress.line());
    assert!(progress.line().contains("too_old=1"), "{}", progress.line());
    assert_eq!(progress.stopped, None, "an old message is skipped, not a reason to stop");
    // The old one is not in the index; the two inside the window are.
    assert!(block_on(index::load(&store, CHAT, "OLD")).unwrap().is_none());
    assert!(block_on(index::load(&store, CHAT, "KEPT")).unwrap().is_some());
    assert!(block_on(index::load(&store, CHAT, "NEW")).unwrap().is_some());
}

#[test]
fn a_deep_chat_is_bounded_by_age_and_not_by_a_count() {
    // The cap that is gone: a chat may hold more backfilled records than the old 200 per chat, as long
    // as they are inside the window. The only count left is the per-notification one.
    let store = Memory::new();
    let progress = drain(&store, &text_chat(CHAT, 260), keeping(1_000, 180));
    assert_eq!(progress.written, 260, "{}", progress.line());
    assert_eq!(progress.stopped, None, "{}", progress.line());

    // And the index may hold more than the old 2000-total, which went with it.
    let mut total = 0;
    for chat in 0..9 {
        let id = format!("12036300000000000{chat}@g.us");
        total += drain(&store, &text_chat(&id, 260), keeping(1_000, 180)).written;
    }
    assert!(total > 2_000, "the past is bounded by age, not by a total: {total}");
}

#[test]
fn the_per_sync_budget_spreads_a_blob_over_ticks() {
    let store = Memory::new();
    let progress = drain(&store, &text_chat(CHAT, 10), budget(3));
    assert_eq!((progress.written, progress.remaining), (3, 7), "{}", progress.line());
    assert_eq!(progress.stopped, Some(Stop::Sync));
    // Nothing was lost: the next sync (or the next chunk) indexes more.
    let again = drain(&store, &text_chat(CHAT, 10), budget(3));
    assert_eq!(again.written, 3);
    assert_eq!(again.duplicate, 3, "the first three are already indexed");
}

#[test]
fn an_off_budget_writes_nothing_and_says_so() {
    let store = Memory::new();
    let progress = drain(&store, &text_chat(CHAT, 3), Budget::off());
    assert_eq!(progress.written, 0);
    assert_eq!(progress.stopped, Some(Stop::Off));
    assert!(progress.line().contains("stopped=off"), "{}", progress.line());
    assert!(store.is_empty());
}

#[test]
fn the_window_is_the_one_the_live_index_is_pruned_by() {
    // One clock for both halves: `index_retention_days` bounds what arrives from the phone and what
    // stays in the store. A definition that still names the removed caps is not refused - their keys
    // simply do not reach the budget.
    let config = serde_json::json!({
        "index_retention_days": 30,
        "index_history_per_sync": 40,
        "index_history_per_chat": 200,
        "index_history_total": 2_000,
    });
    let budget = Budget::from_json(&config);
    assert_eq!(budget.per_sync, 40);
    assert_eq!(budget.keep_ms, 30 * 86_400_000);
    assert_eq!(budget.oldest_ms(NOW), NOW - 30 * 86_400_000);
    // Absent keys: the seam's defaults, 180 days.
    let defaults = Budget::from_json(&serde_json::json!({}));
    assert_eq!(defaults.keep_ms, 180 * 86_400_000);
    assert_eq!(defaults.per_sync, 1_000);
    assert!(!defaults.is_off());
}

/// A store whose writes fail after `budget` of them: the storage grant, or a broken kv.
struct Failing {
    inner: Memory,
    writes: std::cell::Cell<usize>,
    budget: usize,
}

impl Store for Failing {
    fn get<'a>(&'a self, key: &'a [u8]) -> impl std::future::Future<Output = Result<Option<Vec<u8>>, String>> + 'a {
        self.inner.get(key)
    }
    fn set<'a>(&'a self, key: &'a [u8], value: &'a [u8]) -> impl std::future::Future<Output = Result<(), String>> + 'a {
        let allowed = self.writes.get() < self.budget;
        if allowed {
            self.writes.set(self.writes.get() + 1);
        }
        async move {
            if allowed {
                self.inner.set(key, value).await
            } else {
                Err("quota exceeded".to_string())
            }
        }
    }
    fn del<'a>(&'a self, key: &'a [u8]) -> impl std::future::Future<Output = Result<(), String>> + 'a {
        self.inner.del(key)
    }
    fn scan<'a>(
        &'a self,
        prefix: &'a [u8],
        cursor: Option<Vec<u8>>,
        limit: usize,
    ) -> impl std::future::Future<Output = Result<index::Page, String>> + 'a {
        self.inner.scan(prefix, cursor, limit)
    }
}

#[test]
fn a_failed_write_stops_the_drain_with_a_reason_and_keeps_what_was_written() {
    let store = Failing { inner: Memory::new(), writes: std::cell::Cell::new(0), budget: 1 };
    let progress = block_on(async {
        let mut plan = Plan::new(Budget::default());
        drain_conversation(&store, &text_chat(CHAT, 4), &me(), &mut plan, 1).await
    });
    // One record's `put` is several `set`s, so the first message may be cut mid-write; what matters is
    // that the drain stopped with the store's own word instead of retrying into the same wall.
    assert_eq!(progress.stopped, Some(Stop::Store), "{}", progress.line());
    assert_eq!(progress.reason, "quota exceeded");
    assert!(progress.remaining > 0, "the rest is reported, not silently dropped");
}

// ---- the on-demand request -----------------------------------------------------------------

#[test]
fn an_on_demand_request_names_the_oldest_indexed_message() {
    let store = Memory::new();
    // Three messages already in the index, newest first by timestamp; the oldest is ours.
    for (id, ts, own) in [("M3", 3_000i64, false), ("M1", 1_000, true), ("M2", 2_000, false)] {
        let record = Record {
            chat: CHAT.into(),
            id: id.into(),
            sender: SENDER.into(),
            own,
            ts,
            kind: "text".into(),
            text: "oi".into(),
            ..Record::default()
        };
        block_on(index::put(&store, &record)).expect("a record");
    }
    let one = block_on(anchors(&store, Some(CHAT), 120)).expect("anchors");
    assert_eq!(one.len(), 1);
    assert_eq!(one[0].chat, CHAT);
    assert_eq!(one[0].id, "M1", "the anchor is the oldest message we hold");
    assert_eq!(one[0].ts, 1_000);
    assert!(one[0].from_me, "the phone needs to know whose message the anchor is");
    assert_eq!(one[0].count, 120);
    // The request the seam carries is the same fact, in the shape the queue validates.
    let wire = one[0].to_seam();
    assert_eq!((wire.chat.as_str(), wire.oldest_id.as_str(), wire.count), (CHAT, "M1", 120));

    // No chat named: the chats the index knows, most recently active first.
    let other = Record { chat: DM.into(), id: "D9".into(), sender: DM.into(), ts: 9_000, ..Record::default() };
    block_on(index::put(&store, &other)).expect("a record");
    let all = block_on(anchors(&store, None, 50)).expect("anchors");
    assert_eq!(all.iter().map(|anchor| anchor.chat.as_str()).collect::<Vec<_>>(), vec![DM, CHAT]);
    assert_eq!(all[0].id, "D9");

    // A chat the index has never seen still gets a request: from the phone's newest messages.
    let unknown = block_on(anchors(&store, Some("5511777776666@s.whatsapp.net"), 10)).expect("anchors");
    assert_eq!((unknown[0].id.as_str(), unknown[0].ts), ("", 0));
    assert!(!unknown[0].from_me);
}

#[test]
fn a_backfill_request_covers_at_most_a_bounded_number_of_chats() {
    let store = Memory::new();
    for i in 0..(seam::BACKFILL_MAX_CHATS + 5) {
        let record = Record {
            chat: format!("5511999900{i:02}@s.whatsapp.net"),
            id: format!("X{i}"),
            sender: SENDER.into(),
            ts: 1_000 + i as i64,
            kind: "text".into(),
            ..Record::default()
        };
        block_on(index::put(&store, &record)).expect("a record");
    }
    let all = block_on(anchors(&store, None, 50)).expect("anchors");
    assert_eq!(all.len(), seam::BACKFILL_MAX_CHATS, "one request per chat, and a request is a message");
}

// ---- the envelope a history message builds -------------------------------------------------

#[test]
fn a_history_message_is_attributed_to_its_author_or_to_us() {
    let group = conversation(
        CHAT,
        vec![
            entry(CHAT, "G1", BASE_TS, "oi", false, Some(SENDER)),
            entry(CHAT, "G2", BASE_TS + 1, "oi de volta", true, None),
        ],
    );
    let group_messages = candidates(&group, &me());
    assert_eq!(group_messages.len(), 2);
    assert_eq!(group_messages[0].envelope.sender, SENDER, "a group message names its author");
    assert!(group_messages[0].envelope.group);
    assert_eq!(group_messages[0].envelope.ts, (BASE_TS as i64) * 1000, "seconds become milliseconds");
    assert_eq!(group_messages[1].envelope.sender, OWN_LID, "our own message is ours");
    assert!(group_messages[1].envelope.own);

    // A DM with no participant: the chat is the author.
    let dm = conversation(DM, vec![entry(DM, "D1", BASE_TS, "oi", false, None)]);
    let dm_messages = candidates(&dm, &me());
    assert_eq!(dm_messages[0].envelope.sender, DM);
    assert!(!dm_messages[0].envelope.group);

    // A message with no id, or no message at all, is not a candidate: an index keyed by id cannot
    // hold it, and inventing one would make the dedupe a lie.
    let mut nameless = entry(CHAT, "X", BASE_TS, "oi", false, None);
    if let Some(info) = nameless.message.as_option_mut() {
        info.key.as_option_mut().and_then(|key| key.id.take());
    }
    let empty = conversation(CHAT, vec![nameless, wap::HistorySyncMsg::default()]);
    assert!(candidates(&empty, &me()).is_empty());
}

#[test]
fn status_and_newsletter_traffic_is_not_a_chat() {
    assert!(!followed("status@broadcast"));
    assert!(!followed("120363000000000001@newsletter"));
    assert!(!followed(""));
    assert!(followed(CHAT));
    let status = conversation("status@broadcast", vec![entry("status@broadcast", "S1", BASE_TS, "oi", false, None)]);
    assert!(candidates(&status, &me()).is_empty(), "the live path skips status, and so does the past");
}
