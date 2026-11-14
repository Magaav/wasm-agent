//! The message index: every received message, in the component's own kv, queryable.
//!
//! The store is the component's `wa:kernel/kv` namespace, so the index is bounded by the same storage
//! grant as the rest of the component's state and is never visible to another component. Keys live
//! below one prefix ([`PREFIX`]) because the queue has its own sub-namespace (`q/`), the protocol store
//! its own (`ses/`, `pk/`, …) and the transcription pipeline its own (`tx/`); one owner per prefix is
//! what keeps a scan from walking into somebody else's keys.
//!
//! ```text
//! ix/m/<chat>/<inv(ts)>/<id>            the record, JSON            (a thread read: newest first)
//! ix/id/<chat>/<id>                     inv(ts)                     (id -> thread key, media, download)
//! ix/s/<sender>/<inv(ts)>/<id>/<chat>   empty                       (by sender)
//! ix/k/<kind>/<inv(ts)>/<id>/<chat>     empty                       (by kind)
//! ix/w/<token>/<inv(ts)>/<id>/<chat>    empty                       (normalized-token index)
//! ix/x/<chat>/<id>/<reactor>/<emoji>    reaction, JSON              (folded onto its target)
//! ix/all/<ts>/<chat>/<id>              `history` | empty            (age order: retention walks it)
//! ix/pend/<chat>/<id>                   a mutation for a message not indexed yet
//! ix/ocr/<chat>/<id>                    the OCR lane's mark, JSON      (a terminal reason or a retry)
//! ```
//!
//! `inv(ts)` is `u64::MAX - ts` as fixed-width hex, so an ascending scan yields the newest message
//! first and `<before>` is a cursor: the graph and the transcript read the same direction as the phone.
//! `ix/all` is the opposite (plain `ts`, oldest first) because retention walks from the oldest.
//!
//! Decisions worth naming:
//!
//! * **A message that has not arrived yet is not a hole.** A revoke or an edit can arrive before the
//!   message it names (a re-delivery, a history sync); the mutation is kept under `ix/pend` and applied
//!   when the record lands, so a deleted message is never indexed with its text.
//! * **Reactions are folded, not threads.** A reaction is recorded (who, which emoji, to which message)
//!   and attached to its target; `read` shows it on the message, and it is not a separate bubble.
//!   An empty emoji is a removal: the same actor's row is deleted, not overwritten with a blank.
//! * **Deleting a message deletes its text.** A revoke clears the text, the media keys and every token
//!   entry, so a search can never return words the sender took back; the row stays as the event that
//!   says it happened.
//! * **Retention is by age, in bounded passes.** No count is maintained (a counter that drifts is a
//!   counter that deletes live data); [`prune`] walks `ix/all` from the oldest and stops at the first
//!   record inside the window or at its budget, and the caller runs it again next tick.
use crate::record::{self, Record};
use std::collections::{BTreeSet, HashMap, HashSet};
use wa_whatsapp_index as seam;

/// Every key this module owns starts here (the component's `kv.write` policy rules it as `ix/*`).
pub const PREFIX: &str = "ix/";
/// Most token keys one record writes. A long document's caption is not a thesaurus.
pub const MAX_TOKENS: usize = seam::MAX_TOKENS;
/// How many candidates one narrowing may collect before the answer is "narrow it down".
const CANDIDATE_BUDGET: usize = 2_000;
/// How many records a search may load to rank them.
const LOAD_BUDGET: usize = 400;
/// Page size for a scan.
const PAGE: usize = 200;
/// Most reactions folded onto one message in an answer.
const MAX_FOLDED: usize = seam::MAX_LISTED;
/// How many chat cards (chats this node has seen) one name question may read.
const CARD_BUDGET: usize = 2_000;

/// How many times a record whose write was refused is handed back to the ingest lane before it is
/// reported and dropped.
///
/// This is a decision and not a host call, so it is here, beside the keys it protects, and measured by
/// `cargo test` - the lane that uses it (`guest::index_inbox`) is wasm-only. The refusal a record
/// actually meets is the component's kv grant running out of tokens for the minute
/// (`capability_rate_limited`, `policies/default.json`); a bucket refills in 60 s, so a handful of the
/// lane's one-second ticks is enough, and a store that refuses one record for any other reason forever
/// must not become a stuck inbox.
pub const RETRY_LIMIT: u8 = 8;

/// What the ingest lane does with a record whose write was refused, given how many times it already
/// has been.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refused {
    /// Hand it back: the refusal is (almost always) the write budget, which refills.
    Retry,
    /// Report it and let it go: a record that has been refused this many times is not going to be
    /// written by trying once more, and a line is better than an inbox that never drains.
    Drop,
}

/// The policy of [`Refused`], in one place.
pub fn refused(attempts: u8) -> Refused {
    if attempts < RETRY_LIMIT {
        Refused::Retry
    } else {
        Refused::Drop
    }
}

// ---- the store seam ------------------------------------------------------------------------------

/// One page of a scan: `(key, value)` pairs, ordered by key.
pub type Page = Vec<(Vec<u8>, Vec<u8>)>;

/// The four kv calls this module needs, in the shape the guest's async kv has.
///
/// `wa:kernel@0.2`'s kv is `async fn`; a native test's is immediate. Keeping the trait async is what
/// lets the same `put`/`search`/`prune` code run in the component and in `cargo test` (the tests drive
/// it with [`Memory`], which is the same contract without a host).
pub trait Store {
    fn get<'a>(&'a self, key: &'a [u8]) -> impl std::future::Future<Output = Result<Option<Vec<u8>>, String>> + 'a;
    fn set<'a>(&'a self, key: &'a [u8], value: &'a [u8]) -> impl std::future::Future<Output = Result<(), String>> + 'a;
    fn del<'a>(&'a self, key: &'a [u8]) -> impl std::future::Future<Output = Result<(), String>> + 'a;
    /// Entries under `prefix`, ordered by key, after `cursor` (exclusive).
    fn scan<'a>(
        &'a self,
        prefix: &'a [u8],
        cursor: Option<Vec<u8>>,
        limit: usize,
    ) -> impl std::future::Future<Output = Result<Page, String>> + 'a;
}

/// An in-memory store: the tests' host, ordered by key exactly as `wa:kernel/kv` is.
#[derive(Default)]
pub struct Memory {
    keys: std::cell::RefCell<std::collections::BTreeMap<Vec<u8>, Vec<u8>>>,
}

impl Memory {
    pub fn new() -> Memory {
        Memory::default()
    }

    pub fn len(&self) -> usize {
        self.keys.borrow().len()
    }

    pub fn is_empty(&self) -> bool {
        self.keys.borrow().is_empty()
    }

    /// Every key currently stored, for the tests that assert a deletion took its secondary keys too.
    pub fn keys(&self) -> Vec<String> {
        self.keys.borrow().keys().map(|key| String::from_utf8_lossy(key).into_owned()).collect()
    }
}

impl Store for Memory {
    fn get<'a>(&'a self, key: &'a [u8]) -> impl std::future::Future<Output = Result<Option<Vec<u8>>, String>> + 'a {
        let found = self.keys.borrow().get(key).cloned();
        async move { Ok(found) }
    }

    fn set<'a>(&'a self, key: &'a [u8], value: &'a [u8]) -> impl std::future::Future<Output = Result<(), String>> + 'a {
        self.keys.borrow_mut().insert(key.to_vec(), value.to_vec());
        async move { Ok(()) }
    }

    fn del<'a>(&'a self, key: &'a [u8]) -> impl std::future::Future<Output = Result<(), String>> + 'a {
        self.keys.borrow_mut().remove(key);
        async move { Ok(()) }
    }

    fn scan<'a>(
        &'a self,
        prefix: &'a [u8],
        cursor: Option<Vec<u8>>,
        limit: usize,
    ) -> impl std::future::Future<Output = Result<Page, String>> + 'a {
        let found: Page = self
            .keys
            .borrow()
            .iter()
            .filter(|(key, _)| key.starts_with(prefix))
            .filter(|(key, _)| cursor.as_deref().is_none_or(|cursor| key.as_slice() > cursor))
            .take(limit.max(1))
            .map(|(key, value)| (key.clone(), value.clone()))
            .collect();
        async move { Ok(found) }
    }
}

// ---- keys ----------------------------------------------------------------------------------------

/// `u64::MAX - ts`, 16 hex digits: ascending order is newest first.
fn inv(ts: i64) -> String {
    format!("{:016x}", u64::MAX - (ts.max(0) as u64))
}

/// `ts`, 16 hex digits: ascending order is oldest first.
fn age(ts: i64) -> String {
    format!("{:016x}", ts.max(0) as u64)
}

// The layout itself lives in the seam (`wa_whatsapp_index::keys`), because the node now cuts a month
// out of this index into an archive and puts it back: a second copy of these `format!`s here would be a
// cut that misses a key and a restore that writes a month nobody can search
// (`docs/WHATSAPP-ARCHIVE.md`). These keep the names this module's code reads by.
fn from_age(text: &str) -> Option<i64> {
    seam::keys::from_age(text)
}

fn key_message(chat: &str, ts: i64, id: &str) -> String {
    seam::keys::message(chat, ts, id)
}

fn key_id(chat: &str, id: &str) -> String {
    seam::keys::id(chat, id)
}

fn key_age(ts: i64, chat: &str, id: &str) -> String {
    seam::keys::age_key(ts, chat, id)
}

fn key_sender(sender: &str, ts: i64, id: &str, chat: &str) -> String {
    seam::keys::sender(sender, ts, id, chat)
}

fn key_kind(kind: &str, ts: i64, id: &str, chat: &str) -> String {
    seam::keys::kind(kind, ts, id, chat)
}

fn key_token(token: &str, ts: i64, id: &str, chat: &str) -> String {
    seam::keys::token(token, ts, id, chat)
}

fn key_reaction(chat: &str, target: &str, reactor: &str, emoji: &str) -> String {
    seam::keys::reaction(chat, target, reactor, emoji)
}

fn reaction_prefix(chat: &str, target: &str) -> String {
    seam::keys::reaction_prefix(chat, target)
}

/// The months loaded back from their archives, as `[start, end)` ranges in the age order.
///
/// One small scan of `ix/arc/` (`docs/WHATSAPP-ARCHIVE.md`); an unreadable or foreign mark is skipped,
/// because a mark that cannot name a range cannot protect one.
async fn restored_ranges<S: Store>(store: &S) -> Result<Vec<(i64, i64)>, String> {
    let prefix = seam::keys::archive_prefix();
    let mut out: Vec<(i64, i64)> = Vec::new();
    let mut cursor: Option<Vec<u8>> = None;
    loop {
        let page = store.scan(prefix.as_bytes(), cursor.clone(), 64).await?;
        if page.is_empty() {
            break;
        }
        cursor = page.last().map(|(key, _)| key.clone());
        let short = page.len() < 64;
        for (key, _) in page {
            let text = String::from_utf8_lossy(&key).into_owned();
            if let Some(month) = text.strip_prefix(&prefix) {
                if let Ok(range) = seam::month::bounds(month) {
                    out.push(range);
                }
            }
        }
        if short {
            break;
        }
    }
    out.sort();
    out.dedup();
    Ok(out)
}

/// A scan cursor that sits after every age key below `end_ms`.
///
/// `age()` is fixed-width hex, and no chat id starts with a character above `U+10FFFF`'s bytes, so this
/// key sorts after the last entry of the passed range and before the first entry at or after `end_ms`.
fn jump_key(end_ms: i64) -> Vec<u8> {
    format!("{PREFIX}all/{}/\u{10FFFF}", age(end_ms - 1)).into_bytes()
}

fn key_pending(chat: &str, id: &str) -> String {
    format!("{PREFIX}pend/{chat}/{id}")
}

/// One image the OCR lane already answered: [`OcrMark`] as JSON. Without it the lane's backlog pass
/// would re-download the same screenshot every pass to learn the same thing
/// (`docs/WHATSAPP-OCR.md`).
fn key_ocr_seen(chat: &str, id: &str) -> String {
    seam::keys::ocr_seen(chat, id)
}

// ---- the chats, by the name this node observed ---------------------------------------------------

/// `ix/ct/<chat>` -> one [`ChatCard`].
///
/// It exists because a name is a question the message index can answer without a second store: every
/// inbound message carries the sender's push name, and a group's subject is fetched for an alert
/// anyway. Keeping the answer beside the index (one small row per chat, rewritten on each message)
/// makes `whatsapp_contacts` one bounded scan, instead of one record load per chat the account has
/// ever talked in.
fn key_card(chat: &str) -> String {
    seam::keys::chat_card(chat)
}

/// Most names one card keeps: enough for a person's rename history and a group's active members,
/// few enough that the row stays small.
const CARD_NAMES: usize = 12;
/// Most chats one shared contact card may name: a contact array can be long, and every entry it
/// points at costs a read and (when it lands) a write against the component's kv grant.
const CONTACT_CARDS: usize = 8;

/// One name this node has seen, with how often and how recently.
#[derive(Clone, Debug, Default, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct CardName {
    /// As it was written on the wire (the push name, or the group subject).
    pub name: String,
    /// [`record::fold`] of it: what a query is compared against.
    pub folded: String,
    pub rows: u32,
    pub first: i64,
    pub last: i64,
    /// True when this name was seen on the chat's *own* messages (a direct chat's contact), never on
    /// a group member's.
    pub sender: bool,
    /// True when the name came from a contact card somebody shared, naming this chat's phone number.
    /// It is evidence about that number and not a guess - but it is weaker than the name the person
    /// writes on their own messages, so [`ChatCard::best_name`] only falls back to it.
    pub card: bool,
}

/// One chat as the index knows it: its address, what kind it is, and every name seen there.
#[derive(Clone, Debug, Default, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct ChatCard {
    pub chat: String,
    pub group: bool,
    /// A group's subject, when this node fetched it (alerts, or a metadata lookup). Empty until then:
    /// a group is not named after its members, and a guess here would point a reader at a wrong chat.
    pub subject: String,
    pub names: Vec<CardName>,
    pub first: i64,
    pub last: i64,
    pub rows: u32,
}

impl ChatCard {
    /// The name a reader should see for this chat, and where it came from.
    pub fn best_name(&self) -> (&str, &'static str) {
        if self.group {
            if !self.subject.is_empty() {
                return (&self.subject, "group_subject");
            }
        } else if let Some(name) = self.names.iter().filter(|name| name.sender && !name.name.is_empty()).max_by_key(|name| name.last) {
            return (&name.name, "push_name");
        } else if let Some(name) = self.names.iter().filter(|name| name.card && !name.name.is_empty()).max_by_key(|name| name.last) {
            // The second source a direct chat has: a contact card that names this number. Weaker than
            // the name its owner writes, which is why it is only reached when there is none.
            return (&name.name, "contact_card");
        }
        ("", "jid")
    }

    /// How a query of `folded` (already folded) matches this chat: 3 exact, 2 prefix, 1 substring, 0 no
    /// match, with the name that matched.
    ///
    /// The chat's own address is matched too: a caller with a phone number and no name gets the one
    /// chat that number belongs to, which is not a guess when exactly one chat carries those digits.
    pub fn match_score(&self, folded: &str) -> Option<(u8, String)> {
        if folded.is_empty() {
            return Some((1, self.best_name().0.to_string()));
        }
        let mut best: Option<(u8, String)> = None;
        let mut consider = |text: &str, shown: &str| {
            let candidate = record::fold(text);
            if candidate.is_empty() {
                return;
            }
            let score = if candidate == folded {
                3
            } else if candidate.starts_with(folded) {
                2
            } else if candidate.contains(folded) {
                1
            } else {
                0
            };
            if score > 0 && best.as_ref().is_none_or(|(current, _)| score > *current) {
                best = Some((score, shown.to_string()));
            }
        };
        for name in &self.names {
            consider(&name.name, &name.name);
        }
        if !self.subject.is_empty() {
            consider(&self.subject, &self.subject);
        }
        // The address itself: `5519994939204@s.whatsapp.net` matches on its digits, and so does a
        // group's `<creator>-<epoch>@g.us` id on its first half.
        let user = self.chat.split('@').next().unwrap_or("");
        consider(user, user);
        if let Some((creator, _)) = user.split_once('-') {
            consider(creator, user);
        }
        best
    }
}

/// The word a record's age entry carries: `history` for a backfilled record, empty for a live one.
///
/// The age index (`ix/all`) was written with an empty value until history sync existed, and nothing
/// ever read it. Carrying the source there is what makes "how much of the index is backfill" one
/// bounded scan instead of one record load per message - the count a budget has to know before it
/// writes. An entry written by an older build (or by [`repair`] on a record that has none) is empty,
/// which counts as live: an absent source must never be mistaken for a backfilled one.
fn source_word(record: &Record) -> &'static str {
    if record.from_history() {
        "history"
    } else {
        ""
    }
}

/// One candidate message a narrowing produced: its thread key can be rebuilt from `(chat, ts, id)`.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct Candidate {
    chat: String,
    id: String,
    inv: String,
}

// ---- writing -------------------------------------------------------------------------------------

/// Index one record: a message, or the event a reaction/edit/delete is.
pub async fn put<S: Store>(store: &S, record: &Record) -> Result<(), String> {
    match record.kind.as_str() {
        "reaction" => put_reaction(store, record).await,
        "edit" => {
            put_event(store, record).await?;
            apply_edit(store, record).await
        }
        "delete" => {
            put_event(store, record).await?;
            apply_delete(store, record).await
        }
        _ => put_message(store, record).await,
    }
}

/// Store a message, after applying a mutation that arrived before it did.
async fn put_message<S: Store>(store: &S, record: &Record) -> Result<(), String> {
    let pending = pending_of(store, &record.chat, &record.id).await?;
    let mut record = record.clone();
    if let Some(pending) = pending {
        // The order the network chose is not the order the phone shows: a revoke re-delivered ahead of
        // its message must still win. Never the other way round - text the sender took back is not
        // indexed, not even for the tick it takes the tombstone to arrive.
        match pending.op.as_str() {
            "edit" => {
                if !record.deleted {
                    record.text = pending.text;
                    record.quoted = pending.quoted;
                    record.mentions = pending.mentions;
                    record.edited = true;
                    record.edits = record.edits.max(1);
                    record.event_ts = pending.ts;
                }
            }
            "delete" => redact(&mut record, pending.ts),
            _ => {}
        }
        store.del(key_pending(&record.chat, &record.id).as_bytes()).await?;
    }
    // The name side first, the record second, and the difference matters: the index's writes are
    // charged to the component's `kv.write` grant (a token bucket, `policies/default.json`), a
    // message costs five keys plus one per token, and a bucket that runs out part-way through a
    // message therefore always runs out at the END of the sequence. The card used to be that end, so
    // the one row `whatsapp_contacts` reads was the first thing a busy account lost - and the record,
    // which nothing can rebuild, must not be the price of the name, which `backfill_cards` can.
    let named = card_touch(store, &record).await;
    let named = contact_cards(store, &record).await.and(named);
    write(store, &record).await?;
    named
}

/// Name the chats a shared contact card points at: `record.contacts` carries vCard names and the
/// phone numbers they belong to, and a direct chat's address is a phone number.
///
/// Only a chat the index already holds is named: a card somebody shared is not a conversation, and
/// writing one here would make `whatsapp_contacts` (which lists the chats the index knows) claim a
/// chat no message ever came from. The name is marked [`CardName::card`], so it never outranks the
/// name the person writes on their own messages.
///
/// Bounded by [`CONTACT_CARDS`] per message: a contact array can be long, and each entry costs a
/// read and (when it lands) a write against the same grant as everything else.
async fn contact_cards<S: Store>(store: &S, record: &Record) -> Result<(), String> {
    let mut named = 0usize;
    for contact in &record.contacts {
        if named >= CONTACT_CARDS {
            break;
        }
        let name = contact.name.trim();
        if name.is_empty() {
            continue;
        }
        let folded = record::fold(name);
        if folded.is_empty() {
            continue;
        }
        for phone in &contact.phones {
            let chat = format!("{phone}@s.whatsapp.net");
            let Some(mut card) = card_of(store, &chat).await? else { continue };
            if card.group || card.names.iter().any(|entry| entry.folded == folded) {
                continue;
            }
            card.names.push(CardName {
                name: name.chars().take(seam::MAX_NAME_CHARS).collect(),
                folded: folded.clone(),
                rows: 1,
                first: record.ts,
                last: record.ts,
                sender: false,
                card: true,
            });
            card.names.sort_by(|a, b| b.last.cmp(&a.last).then_with(|| a.folded.cmp(&b.folded)));
            card.names.truncate(CARD_NAMES);
            put_card(store, &card).await?;
            named += 1;
        }
    }
    Ok(())
}

/// Write (or rewrite) a record and every key that points at it.
async fn write<S: Store>(store: &S, record: &Record) -> Result<(), String> {
    let json = serde_json::to_vec(record).map_err(|error| format!("record encode: {error}"))?;
    store.set(key_message(&record.chat, record.ts, &record.id).as_bytes(), &json).await?;
    store.set(key_id(&record.chat, &record.id).as_bytes(), inv(record.ts).as_bytes()).await?;
    store.set(key_age(record.ts, &record.chat, &record.id).as_bytes(), source_word(record).as_bytes()).await?;
    store.set(key_sender(&record.sender, record.ts, &record.id, &record.chat).as_bytes(), b"").await?;
    store.set(key_kind(&record.kind, record.ts, &record.id, &record.chat).as_bytes(), b"").await?;
    for token in record.tokens() {
        store.set(key_token(&token, record.ts, &record.id, &record.chat).as_bytes(), b"").await?;
    }
    Ok(())
}

/// Remove a record and every key that points at it (the reaction rows are the target's, not this
/// record's, and are removed by [`apply_delete`]).
async fn remove<S: Store>(store: &S, record: &Record) -> Result<(), String> {
    store.del(key_message(&record.chat, record.ts, &record.id).as_bytes()).await?;
    store.del(key_ocr_seen(&record.chat, &record.id).as_bytes()).await?;
    store.del(key_id(&record.chat, &record.id).as_bytes()).await?;
    store.del(key_age(record.ts, &record.chat, &record.id).as_bytes()).await?;
    store.del(key_sender(&record.sender, record.ts, &record.id, &record.chat).as_bytes()).await?;
    store.del(key_kind(&record.kind, record.ts, &record.id, &record.chat).as_bytes()).await?;
    for token in record.tokens() {
        store.del(key_token(&token, record.ts, &record.id, &record.chat).as_bytes()).await?;
    }
    Ok(())
}

// ---- the names this node observed: the card, and the two questions it answers --------------------

/// Read one chat's card. A card this build never wrote is `None`, which is not an error: the index of
/// an older build has messages and no names, and a query over it answers with what it has.
async fn card_of<S: Store>(store: &S, chat: &str) -> Result<Option<ChatCard>, String> {
    let Some(value) = store.get(key_card(chat).as_bytes()).await? else { return Ok(None) };
    Ok(serde_json::from_slice::<ChatCard>(&value).ok().filter(|card| !card.chat.is_empty()))
}

/// Every card the index holds, bounded by [`CARD_BUDGET`].
async fn cards<S: Store>(store: &S) -> Result<Vec<ChatCard>, String> {
    let mut cursor: Option<Vec<u8>> = None;
    let mut out = Vec::new();
    loop {
        let page = store.scan(format!("{PREFIX}ct/").as_bytes(), cursor.clone(), PAGE).await?;
        if page.is_empty() {
            break;
        }
        cursor = page.last().map(|(key, _)| key.clone());
        let short = page.len() < PAGE;
        for (_, value) in page {
            if out.len() >= CARD_BUDGET {
                return Ok(out);
            }
            if let Ok(card) = serde_json::from_slice::<ChatCard>(&value) {
                if !card.chat.is_empty() {
                    out.push(card);
                }
            }
        }
        if short {
            break;
        }
    }
    Ok(out)
}

/// How many entries one count walks before it answers "at least this many".
///
/// A count is context for an answer, not a report: `contacts` says how much of the index the name
/// side covers, and a scan that walks fifty thousand age keys to say it exactly is a scan nobody
/// asked for. The answer carries the bound it stopped at (`messages_capped`).
pub const COUNT_CAP: usize = 5_000;

/// Fold one record into a chat's card, in memory: the whole of the name bookkeeping, without a store.
///
/// Split from [`card_touch`] so a backfill can fold every record of one chat and write the card
/// once: the index's keys are ordered by chat, so a page of records is a handful of chats, and one
/// write per chat instead of one per message is what keeps a rebuild of a restored index inside the
/// kv's write budget.
fn card_fold(card: &mut ChatCard, record: &Record) {
    card.chat = record.chat.clone();
    card.group = record.group || record.chat.ends_with("@g.us");
    if card.first == 0 || (record.ts > 0 && record.ts < card.first) {
        card.first = record.ts;
    }
    if record.ts > card.last {
        card.last = record.ts;
    }
    card.rows = card.rows.saturating_add(1);
    let name = record.push_name.trim();
    if !name.is_empty() {
        let folded = record::fold(name);
        // The chat's own contact: their message in a direct chat. An own message carries the account's
        // push name, which is a name this node has seen but is not the chat's.
        let own_contact = !record.own && record.sender == record.chat;
        match card.names.iter_mut().find(|entry| entry.folded == folded) {
            Some(entry) => {
                entry.rows = entry.rows.saturating_add(1);
                entry.sender = entry.sender || own_contact;
                if entry.first == 0 || record.ts < entry.first {
                    entry.first = record.ts;
                }
                if record.ts > entry.last {
                    entry.last = record.ts;
                }
            }
            None => card.names.push(CardName {
                name: name.chars().take(seam::MAX_NAME_CHARS).collect(),
                folded,
                rows: 1,
                first: record.ts,
                last: record.ts,
                sender: own_contact,
                card: false,
            }),
        }
        // Most recent first, then by name so two equally recent names have a stable order, and
        // bounded: a busy group does not grow a card without limit.
        card.names.sort_by(|a, b| b.last.cmp(&a.last).then_with(|| a.folded.cmp(&b.folded)));
        card.names.truncate(CARD_NAMES);
    }
}

/// One card as the bytes the index keeps: the encode that can fail, in one place for the writers.
fn card_json(card: &ChatCard) -> Result<Vec<u8>, String> {
    serde_json::to_vec(card).map_err(|error| format!("card encode: {}", error))
}

/// Write one chat's card: one small row, rewritten in place.
async fn put_card<S: Store>(store: &S, card: &ChatCard) -> Result<(), String> {
    if card.chat.is_empty() {
        return Ok(());
    }
    let json = card_json(card)?;
    store.set(key_card(&card.chat).as_bytes(), &json).await
}

/// Keep one chat's card current. Called on every indexed message: one row per chat, rewritten.
///
/// It records the sender's push name - never the account's own - and marks whether the name was seen
/// on the chat's own messages (`sender`), which is what makes a direct chat's name *that contact's*
/// name instead of the name of whoever happened to talk. A group's subject is not on a message: it is
/// written by [`set_subject`] when this node fetches it, and until then a group has no name and says
/// so (`name_source: "jid"`).
async fn card_touch<S: Store>(store: &S, record: &Record) -> Result<(), String> {
    let mut card = card_of(store, &record.chat).await?.unwrap_or_default();
    card_fold(&mut card, record);
    put_card(store, &card).await
}

// ---- the name side of an index that already holds messages ---------------------------------------

/// Where the card backfill got to: the last `ix/m` key it folded, under the index's own prefix.
fn key_backfill() -> String {
    format!("{PREFIX}bf/cards")
}

/// The mark that says the backfill finished, so a later tick costs one read.
fn key_backfill_done() -> String {
    format!("{PREFIX}bf/cards/done")
}

/// What one backfill pass did.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct CardsBackfilled {
    /// Records folded this pass.
    pub visited: usize,
    /// Cards written this pass: one per chat the pass touched.
    pub chats: usize,
    /// True when there was nothing left to fold, so the name side is complete.
    pub done: bool,
}

/// Derive the chat cards from the records the index already holds.
///
/// The name side of the index (`ix/ct/`) is written as a side effect of indexing a *message*
/// ([`card_touch`]), and until this existed nothing could build it out of records already stored. So
/// an index whose records arrived before `ix/ct` did (384b2b4d, 11/11) - or from a build whose card
/// write failed, or alongside a component store restored on its own (the account node reports
/// `store: 57310 entries restored`) - answers `whatsapp_contacts` with `count: 0` for **every**
/// query, including the one that names no chat and asks what the index knows. The messages are
/// there, the names are not, and from the answer the two states are indistinguishable (13/11, the
/// account node: every contacts query empty while the index was full).
///
/// The records are the source, then: walk `ix/m` (keyed by chat, so one page is a handful of chats),
/// fold each chat's records into its card once and write it. Bounded and resumable - the cursor lives
/// under the index's own prefix, one pass costs at most `budget` records and one write per chat it
/// touched, and the pass that reaches the end writes a done mark so every later tick costs one read.
/// A message that arrives while the walk runs is folded by [`card_touch`] as usual, and a subject
/// this node fetched survives, because both paths read-modify-write the same row.
pub async fn backfill_cards<S: Store>(store: &S, budget: usize) -> Result<CardsBackfilled, String> {
    let mut out = CardsBackfilled::default();
    if store.get(key_backfill_done().as_bytes()).await?.is_some() {
        out.done = true;
        return Ok(out);
    }
    let budget = budget.max(1);
    let page_size = PAGE.min(budget);
    let mut cursor = store.get(key_backfill().as_bytes()).await?;
    loop {
        let page = store.scan(format!("{PREFIX}m/").as_bytes(), cursor.clone(), page_size).await?;
        if page.is_empty() {
            store.del(key_backfill().as_bytes()).await?;
            store.set(key_backfill_done().as_bytes(), b"1").await?;
            out.done = true;
            return Ok(out);
        }
        let short = page.len() < page_size;
        // One card per chat, in the order the page names them. A reaction, an edit or a revoke is an
        // event about another message, not a message: the live path does not fold one into a card
        // either (`put` sends it elsewhere), so the walk does not either.
        let mut order: Vec<String> = Vec::new();
        let mut groups: HashMap<String, Vec<Record>> = HashMap::new();
        for (_, value) in &page {
            let Ok(record) = serde_json::from_slice::<Record>(value) else { continue };
            if record.chat.is_empty() || record.is_event() {
                continue;
            }
            if !groups.contains_key(&record.chat) {
                order.push(record.chat.clone());
            }
            groups.entry(record.chat.clone()).or_default().push(record);
        }
        for chat in order {
            let rows = groups.remove(&chat).unwrap_or_default();
            if rows.is_empty() {
                continue;
            }
            let mut card = card_of(store, &chat).await?.unwrap_or_default();
            for record in &rows {
                card_fold(&mut card, record);
            }
            out.visited += rows.len();
            put_card(store, &card).await?;
            out.chats += 1;
        }
        cursor = page.last().map(|(key, _)| key.clone());
        if let Some(key) = &cursor {
            store.set(key_backfill().as_bytes(), key).await?;
        }
        if short {
            store.del(key_backfill().as_bytes()).await?;
            store.set(key_backfill_done().as_bytes(), b"1").await?;
            out.done = true;
            return Ok(out);
        }
        if out.visited >= budget {
            return Ok(out);
        }
    }
}

/// Where the card backfill stands: `ready` (done), `rebuilding` (a walk is in progress) or
/// `pending` (it has not run yet). The word an answer carries, never a guess.
pub async fn backfill_state<S: Store>(store: &S) -> Result<&'static str, String> {
    if store.get(key_backfill_done().as_bytes()).await?.is_some() {
        return Ok("ready");
    }
    if store.get(key_backfill().as_bytes()).await?.is_some() {
        return Ok("rebuilding");
    }
    Ok("pending")
}

/// How many records the index holds, bounded by `cap`: `(count, capped)`.
pub async fn record_count<S: Store>(store: &S, cap: usize) -> Result<(usize, bool), String> {
    let prefix = format!("{PREFIX}all/");
    let cap = cap.max(1);
    let mut cursor: Option<Vec<u8>> = None;
    let mut count = 0usize;
    loop {
        let page = store.scan(prefix.as_bytes(), cursor.clone(), PAGE).await?;
        if page.is_empty() {
            return Ok((count, false));
        }
        cursor = page.last().map(|(key, _)| key.clone());
        count += page.len();
        if page.len() < PAGE {
            return Ok((count, false));
        }
        if count >= cap {
            return Ok((count, true));
        }
    }
}

/// Record a group's subject, when this node fetched it (the alert line, or a metadata lookup).
///
/// A subject is the only honest name a group has: the envelope's push name in a group is the *sender's*,
/// and naming a group after one of its members would point a reader at the wrong chat. It is written
/// beside the card so `whatsapp_contacts` can answer with it later without a protocol call.
pub async fn set_subject<S: Store>(store: &S, chat: &str, subject: &str) -> Result<(), String> {
    let subject = subject.replace(['\n', '\r'], " ").trim().to_string();
    if subject.is_empty() {
        return Ok(());
    }
    let mut card = card_of(store, chat).await?.unwrap_or_default();
    card.chat = chat.to_string();
    card.group = true;
    card.subject = subject.chars().take(120).collect();
    let json = serde_json::to_vec(&card).map_err(|error| format!("card encode: {error}"))?;
    store.set(key_card(chat).as_bytes(), &json).await
}

/// One candidate chat, as `whatsapp_contacts` lists it.
fn candidate_json(score: u8, card: &ChatCard, matched: &str) -> serde_json::Value {
    let (name, source) = card.best_name();
    let mut out = serde_json::json!({
        "chat": card.chat,
        "type": if card.group { "group" } else { "person" },
        "name": name,
        "name_source": source,
        "matched": matched,
        "confidence": match score { 3 => "exact", 2 => "prefix", _ => "partial" },
        "messages": card.rows,
        "last_at": card.last,
        "at_local": crate::view::local(card.last),
        "at_iso": crate::view::iso(card.last),
        "names": card.names.iter().take(seam::MAX_LISTED).map(|entry| serde_json::json!({
            "name": entry.name, "messages": entry.rows, "last_at": entry.last,
        })).collect::<Vec<_>>(),
    });
    if !card.group && !name.is_empty() {
        out["jid"] = serde_json::Value::String(card.chat.clone());
    }
    out
}

/// Every chat whose observed name matches, best first: the one ranking both `whatsapp_contacts` and a
/// `whatsapp_read` by name use, so the two can never disagree about which chat "Laura" is.
async fn ranked<S: Store>(store: &S, query: &str) -> Result<Vec<(u8, ChatCard, String)>, String> {
    Ok(rank(&cards(store).await?, query))
}

/// The same ranking over cards already in hand: `contacts` reads them once, so the count it reports
/// and the list it answers come from one scan, not two.
fn rank(list: &[ChatCard], query: &str) -> Vec<(u8, ChatCard, String)> {
    let folded = record::fold(query);
    let mut matches: Vec<(u8, ChatCard, String)> = Vec::new();
    for card in list {
        if let Some((score, matched)) = card.match_score(&folded) {
            matches.push((score, card.clone(), matched));
        }
    }
    // Best score first; between equals the chat heard from most recently; then the address, so one
    // query answered twice lists the same order. A question with no name ("what chats does the index
    // know") scores every chat alike, so the order it gets is the one a reader wants: newest first.
    matches.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| b.1.last.cmp(&a.1.last)).then_with(|| a.1.chat.cmp(&b.1.chat)));
    matches
}

/// What a name resolved to: one chat, several, or none. Never a guess.
pub enum Resolved {
    One(String, u8, String),
    Many(Vec<serde_json::Value>),
    None,
}

/// Resolve a name to a chat: the top-scoring matches only, and several of them is an answer with the
/// candidates, not a pick.
async fn resolve_chat<S: Store>(store: &S, name: &str) -> Result<Resolved, String> {
    let matches = ranked(store, name).await?;
    let Some(top) = matches.first().map(|(score, _, _)| *score) else { return Ok(Resolved::None) };
    let best: Vec<&(u8, ChatCard, String)> = matches.iter().filter(|(score, _, _)| *score == top).collect();
    if best.len() == 1 {
        let (score, card, matched) = best[0];
        return Ok(Resolved::One(card.chat.clone(), *score, matched.clone()));
    }
    Ok(Resolved::Many(
        best.iter()
            .take(seam::CONTACTS_MAX as usize)
            .map(|(score, card, matched)| candidate_json(*score, card, matched))
            .collect(),
    ))
}

/// The ops this component's query worker answers, in the seam's own order.
///
/// The dispatch in `guest.rs` is a `match` over [`seam::Op`], so the compiler already refuses a new op
/// that nobody handles. What this list adds is a set a TEST can compare with
/// [`seam::Op::ALL`](wa_whatsapp_index::Op::ALL): a component built from a tree where one op is missing
/// fails its own tests instead of refusing that op at run time, which is what a live node saw on 13/11
/// (`contacts` answered `bad_op` on the account node, was retried, and dead-lettered).
pub const OPS: [seam::Op; 8] = [
    seam::Op::Search,
    seam::Op::Read,
    seam::Op::Message,
    seam::Op::Reactions,
    seam::Op::Media,
    seam::Op::Download,
    seam::Op::Backfill,
    seam::Op::Contacts,
];

/// `whatsapp_contacts`: which chats the index knows, by the name it observed.
///
/// The answer is a list, never a decision. One exact match also fills `chat`, so a caller holding one
/// name can go straight to a read; more than one match leaves `chat` empty and says `ambiguous: true`,
/// because picking the wrong Laura is exactly the mistake this question exists to prevent.
pub async fn contacts<S: Store>(store: &S, request: &seam::Verified) -> Result<serde_json::Value, String> {
    let query = request.q.clone().unwrap_or_default();
    // One scan of the name side, then rank in memory: the count the answer reports and the list it
    // carries have to come from the same read.
    let all = cards(store).await?;
    let chats = all.len();
    let matches = rank(&all, &query);
    let total = matches.len();
    let kept: Vec<(u8, ChatCard, String)> = matches.into_iter().take(request.limit as usize).collect();
    let top = kept.first().map(|(score, _, _)| *score).unwrap_or(0);
    let top_count = kept.iter().filter(|(score, _, _)| *score == top).count();
    let candidates: Vec<serde_json::Value> = kept.iter().map(|(score, card, matched)| candidate_json(*score, card, matched)).collect();
    let mut answer = serde_json::json!({
        "q": query,
        "candidates": candidates,
        "count": candidates.len(),
        "matched": total,
        "truncated": total > candidates.len(),
        "ambiguous": top_count > 1,
    });
    if top_count == 1 {
        if let Some(first) = answer["candidates"].as_array().and_then(|list| list.first()).cloned() {
            answer["chat"] = first["chat"].clone();
            if total > 1 {
                // One clear best, with weaker names beside it: the chat is still the answer, and
                // `others` says how many chats matched only partly.
                answer["others"] = serde_json::Value::from(total - 1);
            }
        }
    }
    // What the name side covers, in numbers, so "no chat carries that name" is a fact about the index
    // and not a guess about the account. An index full of messages whose names were never derived and
    // an account nobody has ever talked to used to answer the same sentence (13/11): the counts and
    // the backfill's state are what tell them apart.
    let (messages, capped) = record_count(store, COUNT_CAP).await.unwrap_or((0, false));
    let names = backfill_state(store).await.unwrap_or("pending");
    answer["index"] = serde_json::json!({
        "chats": chats,
        "messages": messages,
        "messages_capped": capped,
        "names": names,
    });
    if total == 0 {
        let note = match (chats, messages) {
            (0, 0) => "no chat in this index carries that name; the index holds no message yet, so it knows no name"
                .to_string(),
            (0, _) => format!(
                "no chat in this index carries that name yet: {messages} message(s) are indexed and the chat names are still being derived from them (names: {names})"
            ),
            (_, _) => format!(
                "no chat in this index carries that name; the index knows {chats} chat(s) - ask with no q to list them, newest first"
            ),
        };
        answer["note"] = serde_json::Value::String(note);
    }
    Ok(seam::answer(seam::Op::Contacts, answer))
}

/// A reaction: the event row (so `kind=reaction` finds it) and the fold onto its target.
async fn put_reaction<S: Store>(store: &S, record: &Record) -> Result<(), String> {
    write(store, record).await?;
    let target = record.target.as_str();
    if target.is_empty() {
        return Ok(());
    }
    // One reaction per actor per message: a new emoji replaces the old, and an empty one removes it.
    for (key, _) in store.scan(format!("{}{}/", reaction_prefix(&record.chat, target), record.sender).as_bytes(), None, 16).await? {
        store.del(&key).await?;
    }
    if record.emoji.is_empty() {
        return Ok(());
    }
    let row = serde_json::json!({
        "sender": record.sender,
        "name": record.push_name,
        "emoji": record.emoji,
        "ts": record.ts,
        "own": record.own,
    });
    let value = serde_json::to_vec(&row).map_err(|error| format!("reaction encode: {error}"))?;
    store.set(key_reaction(&record.chat, target, &record.sender, &record.emoji).as_bytes(), &value).await
}

/// The event row of an edit/delete: an indexed fact with its own id and timestamp.
async fn put_event<S: Store>(store: &S, record: &Record) -> Result<(), String> {
    write(store, record).await
}

async fn apply_edit<S: Store>(store: &S, event: &Record) -> Result<(), String> {
    if event.target.is_empty() {
        return Ok(());
    }
    match load(store, &event.chat, &event.target).await? {
        Some(mut target) => {
            if target.deleted {
                return Ok(()); // an edit after a revoke changes nothing: the message is gone
            }
            let was = target.tokens();
            target.text = event.text.clone();
            target.quoted = event.quoted.clone();
            target.mentions = event.mentions.clone();
            target.edited = true;
            target.edits = target.edits.max(1);
            target.event_ts = event.ts;
            for token in was {
                store.del(key_token(&token, target.ts, &target.id, &target.chat).as_bytes()).await?;
            }
            write(store, &target).await
        }
        None => set_pending(store, &event.chat, &event.target, "edit", Some(event)).await,
    }
}

async fn apply_delete<S: Store>(store: &S, event: &Record) -> Result<(), String> {
    if event.target.is_empty() {
        return Ok(());
    }
    match load(store, &event.chat, &event.target).await? {
        Some(mut target) => {
            // Every token key of the text being taken back goes first: a search must not find a word
            // because the index forgot to forget it.
            for token in target.tokens() {
                store.del(key_token(&token, target.ts, &target.id, &target.chat).as_bytes()).await?;
            }
            redact(&mut target, event.ts);
            // A reaction to a message that no longer exists is not a reaction to anything.
            for (key, _) in store.scan(reaction_prefix(&event.chat, &event.target).as_bytes(), None, 64).await? {
                store.del(&key).await?;
            }
            write(store, &target).await
        }
        None => set_pending(store, &event.chat, &event.target, "delete", None).await,
    }
}

/// What a revoked message keeps: the fact, the envelope and the kind. Not the text, not the media
/// keys, not one token - the sender took it back, and a search that still finds it is a bug.
fn redact(record: &mut Record, event_ts: i64) {
    record.text.clear();
    record.transcript.clear();
    record.ocr.clear();
    record.quoted.clear();
    record.mentions.clear();
    record.media = None;
    record.place = None;
    record.contacts.clear();
    record.poll = None;
    record.deleted = true;
    record.event_ts = event_ts;
}

#[derive(Clone, Debug, Default, serde::Serialize, serde::Deserialize)]
#[serde(default)]
struct Pending {
    op: String,
    text: String,
    quoted: String,
    mentions: Vec<String>,
    ts: i64,
}

async fn set_pending<S: Store>(store: &S, chat: &str, id: &str, op: &str, event: Option<&Record>) -> Result<(), String> {
    let pending = Pending {
        op: op.to_string(),
        text: event.map(|event| event.text.clone()).unwrap_or_default(),
        quoted: event.map(|event| event.quoted.clone()).unwrap_or_default(),
        mentions: event.map(|event| event.mentions.clone()).unwrap_or_default(),
        ts: event.map(|event| event.ts).unwrap_or(0),
    };
    let value = serde_json::to_vec(&pending).map_err(|error| format!("pending encode: {error}"))?;
    store.set(key_pending(chat, id).as_bytes(), &value).await
}

async fn pending_of<S: Store>(store: &S, chat: &str, id: &str) -> Result<Option<Pending>, String> {
    let Some(bytes) = store.get(key_pending(chat, id).as_bytes()).await? else { return Ok(None) };
    Ok(serde_json::from_slice(&bytes).ok())
}

/// Attach text the pipelines produced (a transcript, an OCR pass) to its message and index it, so a
/// search finds a voice note by what was said in it and a photo by what it shows.
pub async fn attach_text<S: Store>(store: &S, chat: &str, id: &str, text: &str, source: Source) -> Result<bool, String> {
    let Some(mut record) = load(store, chat, id).await? else { return Ok(false) };
    if record.deleted || text.is_empty() {
        return Ok(false);
    }
    let was = record.tokens();
    let bounded: String = text.chars().take(record::MAX_TEXT).collect();
    match source {
        Source::Transcript => record.transcript = bounded,
        Source::Ocr => record.ocr = bounded,
    }
    for token in was {
        store.del(key_token(&token, record.ts, &record.id, &record.chat).as_bytes()).await?;
    }
    write(store, &record).await?;
    Ok(true)
}

/// Which pipeline produced an attached text.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Source {
    Transcript,
    Ocr,
}

/// What a previous OCR attempt left under `ix/ocr/<chat>/<id>`: the reason another read is pointless,
/// or a scheduled retry. The reason is always a word (a bounded token, see `ocr::word`), never text.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum OcrMark {
    /// A property of the image, or of this node: another attempt cannot change the answer
    /// (`no_text_detected`, `image_too_large`, the reader is not provisioned), or the retries ran out.
    Terminal { reason: String },
    /// A failure another attempt could change, not before `next_ms` (ms since the epoch). `attempts`
    /// is how many attempts have failed so far, so the cap survives a restart of the component.
    Retry { reason: String, attempts: u32, next_ms: i64 },
}

impl OcrMark {
    /// The word the marker carries, for a log line or a test.
    pub fn reason(&self) -> &str {
        match self {
            OcrMark::Terminal { reason } | OcrMark::Retry { reason, .. } => reason,
        }
    }

    /// Must a pass at `now_ms` skip this image? A terminal mark is forever; a retry is skipped until
    /// its backoff has passed.
    pub fn blocks(&self, now_ms: i64) -> bool {
        match self {
            OcrMark::Terminal { .. } => true,
            OcrMark::Retry { next_ms, .. } => *next_ms > now_ms,
        }
    }
}

/// Remember what one OCR attempt answered, so a later pass does not download the same image to learn
/// it again. Written as JSON; a marker written by an older build (the bare word) still reads as
/// [`OcrMark::Terminal`].
pub async fn mark_ocr<S: Store>(store: &S, chat: &str, id: &str, mark: &OcrMark) -> Result<(), String> {
    let value = serde_json::to_vec(mark).map_err(|error| format!("ocr mark encode: {error}"))?;
    store.set(key_ocr_seen(chat, id).as_bytes(), &value).await
}

/// The mark on this image, if the lane already answered it. One `get`.
pub async fn ocr_mark<S: Store>(store: &S, chat: &str, id: &str) -> Result<Option<OcrMark>, String> {
    let Some(bytes) = store.get(key_ocr_seen(chat, id).as_bytes()).await? else { return Ok(None) };
    if bytes.first() == Some(&b'{') {
        return Ok(serde_json::from_slice(&bytes).ok());
    }
    // A bare word (an older build's marker): a terminal answer, read the same way.
    let word = String::from_utf8_lossy(&bytes).trim().to_string();
    Ok(if word.is_empty() { None } else { Some(OcrMark::Terminal { reason: word }) })
}

/// Forget the mark: the image was read after all (a retry that succeeded), so nothing about it is
/// remembered any more.
pub async fn clear_ocr_mark<S: Store>(store: &S, chat: &str, id: &str) -> Result<(), String> {
    store.del(key_ocr_seen(chat, id).as_bytes()).await
}

/// Remember that this image will not be read again, and why (`no_text_detected`, `image_too_large`).
/// The word is a reason, never text. A later pass sees it and does not re-download the image.
pub async fn mark_unreadable<S: Store>(store: &S, chat: &str, id: &str, word: &str) -> Result<(), String> {
    mark_ocr(store, chat, id, &OcrMark::Terminal { reason: word.to_string() }).await
}

/// Why this image is not worth reading again, if a previous pass decided it is not. One `get`. A
/// pending retry is not an answer: it returns `None`, so the lane may read it when the backoff passes.
pub async fn unreadable<S: Store>(store: &S, chat: &str, id: &str) -> Result<Option<String>, String> {
    Ok(match ocr_mark(store, chat, id).await? {
        Some(OcrMark::Terminal { reason }) => Some(reason),
        _ => None,
    })
}

/// The images a later OCR pass may still read: `(chat, id)` pairs, newest first, at most `budget`.
///
/// The backlog is scanned rather than queued: an image indexed without text (the pipeline was off,
/// the component restarted mid-download, or the record arrived by a history sync) must still become
/// searchable without the owner having to remember which photo it was. Walking `ix/k/image` and
/// `ix/k/document` is one bounded scan per kind instead of a walk over every record, and the pair is
/// returned, not the record: the caller decides what is worth reading (`ocr::wanted`) and downloads
/// under the same media limits the query lane already enforces, so this function duplicates no
/// policy - it only knows which kinds can carry an image.
///
/// An image the lane already answered is not in the backlog: `now_ms` decides whether a scheduled
/// retry is due ([`OcrMark::blocks`]). That is the whole fix for the pass that used to re-download the
/// same eight unreadable screenshots every minute.
pub async fn ocr_backlog<S: Store>(store: &S, budget: usize, now_ms: i64) -> Result<Vec<(String, String)>, String> {
    let mut out: Vec<(String, String)> = Vec::new();
    // The scan reads more candidates than it answers with: a candidate it skips (already read, no
    // media keys) must not starve the pass, and four pages' worth is still a bounded read.
    let scan = budget.saturating_mul(4).clamp(8, PAGE);
    for kind in ["image", "document"] {
        if out.len() >= budget {
            break;
        }
        for candidate in collect(store, format!("{PREFIX}k/{kind}/"), scan).await? {
            if out.len() >= budget {
                break;
            }
            let Some(record) = load(store, &candidate.chat, &candidate.id).await? else { continue };
            if record.deleted || !record.ocr.is_empty() {
                continue;
            }
            if ocr_mark(store, &record.chat, &candidate.id).await?.is_some_and(|mark| mark.blocks(now_ms)) {
                continue;
            }
            let Some(media) = record.media.as_ref().filter(|media| media.downloadable) else { continue };
            // A document only carries an image when its own media type says so: a PDF is a text
            // extraction problem, and queueing it would download it to learn that.
            if kind == "document" && !media.mime.trim().to_ascii_lowercase().starts_with("image/") {
                continue;
            }
            out.push((candidate.chat, candidate.id));
        }
    }
    Ok(out)
}

// ---- reading -------------------------------------------------------------------------------------

/// One message by `(chat, id)`.
pub async fn load<S: Store>(store: &S, chat: &str, id: &str) -> Result<Option<Record>, String> {
    let Some(inv) = store.get(key_id(chat, id).as_bytes()).await? else { return Ok(None) };
    let inv = String::from_utf8_lossy(&inv).into_owned();
    if inv.is_empty() {
        return Ok(None);
    }
    let key = format!("{PREFIX}m/{chat}/{inv}/{id}");
    let Some(bytes) = store.get(key.as_bytes()).await? else { return Ok(None) };
    Ok(serde_json::from_slice(&bytes).ok())
}

/// Does this `(chat, id)` already have a record? One `get`, not a load: a history sync asks this for
/// every message the phone sends, and the answer is the whole of the dedupe.
pub async fn holds<S: Store>(store: &S, chat: &str, id: &str) -> Result<bool, String> {
    Ok(store.get(key_id(chat, id).as_bytes()).await?.is_some_and(|inv| !inv.is_empty()))
}

/// One chat as the age index (`ix/all`) sees it: when it starts, when it ends, how much of it is
/// backfill.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ChatAge {
    pub chat: String,
    /// The oldest record the index holds for this chat (`oldest_id` at `oldest_ts`).
    pub oldest_ts: i64,
    pub oldest_id: String,
    pub newest_ts: i64,
    /// How many of this chat's records came from a history sync.
    pub history: usize,
}

/// The whole age index in one bounded pass: how many backfilled records the index holds, per chat and
/// in total, plus each chat's oldest and newest record.
///
/// This is what a history budget and an on-demand request both need, and both need it *before* they
/// write anything: the pass reads `ix/all` (oldest first) and the value stored beside each key says
/// whether the record was backfilled, so it costs one scan and no record loads. `capped` says the scan
/// hit its entry budget: the counts are then a floor and the chat list is incomplete.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AgeIndex {
    pub entries: usize,
    pub history: usize,
    pub chats: Vec<ChatAge>,
    pub capped: bool,
}

impl AgeIndex {
    pub fn chat(&self, chat: &str) -> Option<&ChatAge> {
        self.chats.iter().find(|entry| entry.chat == chat)
    }

}

/// Walk the age index once, bounded by `cap` entries.
pub async fn age_index<S: Store>(store: &S, cap: usize) -> Result<AgeIndex, String> {
    let mut index = AgeIndex::default();
    let mut cursor: Option<Vec<u8>> = None;
    let prefix = format!("{PREFIX}all/");
    loop {
        let page = store.scan(prefix.as_bytes(), cursor.clone(), PAGE).await?;
        if page.is_empty() {
            return Ok(finish(index));
        }
        cursor = page.last().map(|(key, _)| key.clone());
        let short = page.len() < PAGE;
        for (key, value) in page {
            let text = String::from_utf8_lossy(&key).into_owned();
            let rest = text.strip_prefix(&prefix).unwrap_or_default();
            let parts: Vec<&str> = rest.split('/').collect();
            let [age_text, chat, id] = parts.as_slice() else { continue };
            let Some(ts) = from_age(age_text) else { continue };
            if chat.is_empty() || id.is_empty() {
                continue;
            }
            index.entries += 1;
            let history = value == b"history";
            if history {
                index.history += 1;
            }
            match index.chats.iter_mut().find(|entry| entry.chat == *chat) {
                Some(entry) => {
                    // The scan is oldest first, so the first sighting is the oldest and the last is
                    // the newest.
                    if ts < entry.oldest_ts {
                        entry.oldest_ts = ts;
                        entry.oldest_id = (*id).to_string();
                    }
                    entry.newest_ts = entry.newest_ts.max(ts);
                    if history {
                        entry.history += 1;
                    }
                }
                None => index.chats.push(ChatAge {
                    chat: (*chat).to_string(),
                    oldest_ts: ts,
                    oldest_id: (*id).to_string(),
                    newest_ts: ts,
                    history: usize::from(history),
                }),
            }
            if index.entries >= cap {
                index.capped = true;
                return Ok(finish(index));
            }
        }
        if short {
            return Ok(finish(index));
        }
    }
}

/// Newest activity first, then by chat so one index always lists the same way.
fn finish(mut index: AgeIndex) -> AgeIndex {
    index.chats.sort_by(|a, b| b.newest_ts.cmp(&a.newest_ts).then_with(|| a.chat.cmp(&b.chat)));
    index
}

/// Collect the candidates one prefix offers, newest first, up to `budget`.
async fn collect<S: Store>(store: &S, prefix: String, budget: usize) -> Result<Vec<Candidate>, String> {
    let mut out: Vec<Candidate> = Vec::new();
    let mut cursor: Option<Vec<u8>> = None;
    while out.len() < budget {
        let page = store.scan(prefix.as_bytes(), cursor.clone(), PAGE).await?;
        if page.is_empty() {
            break;
        }
        cursor = page.last().map(|(key, _)| key.clone());
        let short = page.len() < PAGE;
        for (key, _) in page {
            if let Some(candidate) = parse_candidate(&key) {
                out.push(candidate);
            }
        }
        if short {
            break;
        }
    }
    out.truncate(budget);
    Ok(out)
}

/// Rebuild `(chat, inv, id)` from one of this module's keys.
///
/// The thread key is `m/<chat>/<inv>/<id>`; every secondary key is
/// `<s|k|w>/<owner>/<inv>/<id>/<chat>` and ends in the chat, so two chats can never collide on one
/// message id. Both shapes are parsed here because a read walks the first and a search the second.
fn parse_candidate(key: &[u8]) -> Option<Candidate> {
    let text = String::from_utf8_lossy(key);
    let rest = text.strip_prefix(PREFIX)?;
    let parts: Vec<&str> = rest.split('/').collect();
    let (chat, inv, id) = match parts.as_slice() {
        ["m", chat, inv, id] => (*chat, *inv, *id),
        ["s" | "k" | "w", _, inv, id, chat] => (*chat, *inv, *id),
        _ => return None,
    };
    if id.is_empty() || chat.is_empty() || u64::from_str_radix(inv, 16).is_err() {
        return None;
    }
    Some(Candidate { chat: chat.to_string(), id: id.to_string(), inv: inv.to_string() })
}

/// `whatsapp_search`: full text (accent-folded) over text, captions, filenames and transcripts, with
/// the chat/kind/sender/window filters applied on the loaded records.
pub async fn search<S: Store>(store: &S, request: &seam::Verified) -> Result<serde_json::Value, String> {
    let tokens = request.q.as_deref().map(record::tokenize).unwrap_or_default();
    let mut narrowed_list: Option<Vec<Candidate>> = None;
    if !tokens.is_empty() {
        // Every token must hit: `boleto vencimento` is an AND, which is what a person means by typing
        // both. Filtering the posting lists against each other is the whole of the "search engine"
        // here, and the survivors keep their `inv` so the newest are the ones ranked when a broad
        // query matches more than one answer may consider.
        for token in &tokens {
            let list = collect(store, format!("{PREFIX}w/{token}/"), CANDIDATE_BUDGET).await?;
            let survivors: Vec<Candidate> = match narrowed_list.take() {
                None => list,
                Some(previous) => {
                    let set: HashSet<(String, String)> = list.into_iter().map(|candidate| (candidate.chat, candidate.id)).collect();
                    previous.into_iter().filter(|candidate| set.contains(&(candidate.chat.clone(), candidate.id.clone()))).collect()
                }
            };
            if survivors.is_empty() {
                narrowed_list = Some(Vec::new());
                break;
            }
            narrowed_list = Some(survivors);
        }
    } else if request.q.is_some() {
        // A query with no searchable token ("??", "a"): nothing to look for, and saying so is better
        // than answering with the newest messages as though they matched.
        return Ok(seam::answer(
            seam::Op::Search,
            serde_json::json!({"hits": [], "count": 0, "note": "q has no searchable token"}),
        ));
    }

    // No free-text: the filters are the narrowing, and the cheapest one that exists is the source.
    let source = match (&narrowed_list, &request.kind, &request.from, &request.chat) {
        (Some(_), _, _, _) => None,
        (None, Some(kind), _, _) => Some(format!("{PREFIX}k/{kind}/")),
        (None, None, Some(from), _) => Some(format!("{PREFIX}s/{}/", from.jid())),
        (None, None, None, Some(chat)) => Some(format!("{PREFIX}m/{}/", chat.jid())),
        (None, None, None, None) => None,
    };
    let mut list = match (narrowed_list, source) {
        (Some(list), _) => list,
        (None, Some(prefix)) => collect(store, prefix, CANDIDATE_BUDGET).await?,
        (None, None) => Vec::new(),
    };
    // Newest first, and never more than the load budget: an answer ranks at most that many records,
    // and `candidates` says how many the narrowing offered before that cap.
    list.sort_by(|a, b| b.inv.cmp(&a.inv));
    let candidates = list.len();
    list.truncate(LOAD_BUDGET);

    let mut hits: Vec<(i64, serde_json::Value)> = Vec::new();
    // One card read per chat, not per hit: a page of twenty messages is usually three chats.
    let mut names: std::collections::HashMap<String, String> = std::collections::HashMap::new();
    for candidate in list {
        let Some(record) = load(store, &candidate.chat, &candidate.id).await? else { continue };
        if !matches(&record, request) {
            continue;
        }
        let score = score(&record, &tokens, request.q.as_deref());
        let chat_name = match names.get(&record.chat) {
            Some(name) => name.clone(),
            None => {
                let name = card_of(store, &record.chat).await?.map(|card| card.best_name().0.to_string()).unwrap_or_default();
                names.insert(record.chat.clone(), name.clone());
                name
            }
        };
        hits.push((score, hit_json(&record, score, &chat_name)));
    }
    // Best first; between equals, the newest first; between those, a stable id order so one query
    // answered twice returns the same order.
    hits.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| {
        let a_ts = a.1["ts"].as_i64().unwrap_or(0);
        let b_ts = b.1["ts"].as_i64().unwrap_or(0);
        b_ts.cmp(&a_ts).then_with(|| a.1["id"].as_str().cmp(&b.1["id"].as_str()))
    }));
    let total = hits.len();
    let kept: Vec<serde_json::Value> = hits.into_iter().take(request.limit as usize).map(|(_, hit)| hit).collect();
    Ok(seam::answer(
        seam::Op::Search,
        serde_json::json!({
            "q": request.q.clone(),
            "hits": kept,
            "count": total.min(request.limit as usize),
            "matched": total,
            "candidates": candidates,
            "limit": request.limit,
            "truncated": total > kept.len() || candidates > LOAD_BUDGET,
        }),
    ))
}

/// `whatsapp_read`: one thread, newest first, reactions folded onto the messages they answer.
///
/// The chat is an exact JID **or** a name: a name is resolved through the same ranking
/// `whatsapp_contacts` uses, and an ambiguous one answers with the candidates instead of reading
/// whichever chat sorted first (2026-11-11: a model asked to write to "Laura" had no way to find out
/// which Laura the operator meant, and guessed a number).
///
/// The answer is a header plus a page of messages: `chat` (name, type, participants, unread), the
/// messages in [`crate::view::message`]'s shape, and `next_before` as the cursor for the older page.
pub async fn read<S: Store>(store: &S, request: &seam::Verified) -> Result<serde_json::Value, String> {
    let mut resolved: serde_json::Value = serde_json::Value::Null;
    let chat = match (&request.chat, &request.chat_name) {
        (Some(chat), _) => chat.jid(),
        (None, Some(name)) => match resolve_chat(store, name).await? {
            Resolved::One(chat, score, matched) => {
                resolved = serde_json::json!({
                    "from": name, "to": chat, "matched": matched,
                    "confidence": match score { 3 => "exact", 2 => "prefix", _ => "partial" },
                });
                chat
            }
            Resolved::Many(candidates) => {
                let mut answer = seam::refusal(
                    seam::Op::Read,
                    "chat_ambiguous",
                    "more than one chat carries that name; read one of the candidates by its exact JID",
                );
                answer["q"] = serde_json::Value::String(name.clone());
                answer["candidates"] = serde_json::Value::Array(candidates);
                return Ok(answer);
            }
            Resolved::None => {
                let mut answer = seam::refusal(
                    seam::Op::Read,
                    "chat_not_found",
                    "no chat in this index carries that name; ask whatsapp_contacts for what it knows",
                );
                answer["q"] = serde_json::Value::String(name.clone());
                return Ok(answer);
            }
        },
        (None, None) => {
            return Ok(seam::refusal(seam::Op::Read, "chat_required", "read needs the exact chat JID, or a name to resolve"))
        }
    };
    let mut cursor = match &request.before {
        None => None,
        Some(before) => Some(before_cursor(store, &chat, before).await?),
    };
    let mut messages: Vec<serde_json::Value> = Vec::new();
    let mut has_more = false;
    let prefix = format!("{PREFIX}m/{chat}/");
    'pages: loop {
        let page = store.scan(prefix.as_bytes(), cursor.clone(), PAGE).await?;
        if page.is_empty() {
            break;
        }
        cursor = page.last().map(|(key, _)| key.clone());
        let short = page.len() < PAGE;
        for (key, value) in page {
            if parse_candidate(&key).is_none() {
                continue;
            }
            let Ok(record) = serde_json::from_slice::<Record>(&value) else { continue };
            // A reaction is folded onto its target, never a bubble of its own in a thread read.
            if record.kind == "reaction" {
                continue;
            }
            if messages.len() >= request.limit as usize {
                has_more = true;
                break 'pages;
            }
            let quote = quoted_snippet(store, &chat, &record).await?;
            let mut message = crate::view::message(&record, quote.as_deref());
            let folded = fold_reactions(store, &chat, &record.id).await?;
            if !folded.is_empty() {
                message["reactions"] = serde_json::Value::Array(folded);
            }
            messages.push(message);
        }
        if short {
            break;
        }
    }
    let next_before = messages.last().and_then(|message| message["id"].as_str()).map(str::to_string);
    // The header: which chat this is, in words. A card is what the index observed; an index written
    // before the card existed answers with the address and says so.
    let card = card_of(store, &chat).await?;
    let (name, source, group) = match &card {
        Some(card) => (card.best_name().0.to_string(), card.best_name().1, card.group),
        None => (String::new(), "jid", chat.ends_with("@g.us")),
    };
    let participants: Vec<serde_json::Value> = match &card {
        Some(card) if group => card
            .names
            .iter()
            .take(seam::MAX_LISTED)
            .map(|entry| serde_json::json!({ "name": entry.name, "jid": if entry.sender { chat.as_str() } else { "" }, "messages": entry.rows }))
            .collect(),
        _ => Vec::new(),
    };
    let header = crate::view::chat_header(&chat, group, &name, source, participants, messages.len() as u32);
    Ok(seam::answer(
        seam::Op::Read,
        serde_json::json!({
            "chat": chat,
            "header": header,
            "resolved": resolved,
            "messages": messages,
            "count": messages.len(),
            "has_more": has_more,
            "next_before": next_before,
            "limit": request.limit,
        }),
    ))
}

/// The snippet a reply quotes, when the quoted message is in this chat's index.
///
/// `None` is "the index does not have it", which the view writes as an empty quote: a partial
/// history must not look like a message that quoted nothing.
async fn quoted_snippet<S: Store>(store: &S, chat: &str, record: &Record) -> Result<Option<String>, String> {
    if record.quoted.is_empty() {
        return Ok(None);
    }
    Ok(load(store, chat, &record.quoted).await?.map(|quoted| quoted.snippet(seam::MAX_TEXT_CHARS)))
}

/// `whatsapp_message`: one exact message by `(chat, id)`, with its full stored text.
///
/// The read path answers snippets (280 characters) because that is what a model reading a thread
/// needs; an exact reply source and the echo of a sent message are compared against the bytes the
/// index stored, so this op returns the record itself, bounded by the record's own text bound. A
/// missing id is a refusal, never an empty message: "not indexed" is not "the message says nothing".
pub async fn message<S: Store>(store: &S, request: &seam::Verified) -> Result<serde_json::Value, String> {
    let (Some(chat), Some(id)) = (&request.chat, &request.id) else {
        return Ok(seam::refusal(seam::Op::Message, "chat_and_id_required", "one message: pass chat and id"));
    };
    let chat = chat.jid();
    let Some(record) = load(store, &chat, id).await? else {
        return Ok(seam::refusal(seam::Op::Message, "not_found", "no message with that id in this chat"));
    };
    Ok(seam::answer(seam::Op::Message, serde_json::json!({"message": message_json(&record)})))
}

/// One record as the exact-message answer carries it: the fields a caller compares, with the full
/// stored text and no snippet.
fn message_json(record: &Record) -> serde_json::Value {
    let mut message = serde_json::json!({
        "chat": record.chat,
        "id": record.id,
        "ts": record.ts,
        "sender": record.sender,
        "sender_name": record.push_name,
        "kind": record.kind,
        "text": record.text,
        "own": record.own,
    });
    if record.edited {
        message["edited"] = serde_json::Value::Bool(true);
    }
    if record.deleted {
        message["deleted"] = serde_json::Value::Bool(true);
    }
    if !record.unsupported.is_empty() {
        message["unsupported"] = serde_json::Value::String(record.unsupported.clone());
    }
    if record.from_history() {
        message["source"] = serde_json::Value::String(record::SOURCE_HISTORY.to_string());
    }
    if record.restored {
        // An exact-message answer says where it came from, exactly as a hit and a read do
        // (`crate::view::message`, `docs/WHATSAPP-ARCHIVE.md`).
        message["restored"] = serde_json::Value::Bool(true);
        message["restored_month"] = serde_json::Value::String(seam::month::of(record.ts));
    }
    message
}

/// `whatsapp_reactions`: who reacted to one message, with which emoji.
pub async fn reactions<S: Store>(store: &S, request: &seam::Verified) -> Result<serde_json::Value, String> {
    let (Some(chat), Some(id)) = (&request.chat, &request.id) else {
        return Ok(seam::refusal(seam::Op::Reactions, "chat_and_id_required", "one message: pass chat and id"));
    };
    let chat = chat.jid();
    let rows = fold_reactions(store, &chat, id).await?;
    Ok(seam::answer(
        seam::Op::Reactions,
        serde_json::json!({
            "chat": chat,
            "id": id,
            "reactions": rows,
            "count": rows.len(),
            "by_emoji": emoji_tally(&fold_reactions_rows(store, &chat, id).await?),
        }),
    ))
}

/// `whatsapp_media`: the metadata of one message's media - never the bytes, never the media key.
pub async fn media<S: Store>(store: &S, request: &seam::Verified) -> Result<serde_json::Value, String> {
    let (Some(chat), Some(id)) = (&request.chat, &request.id) else {
        return Ok(seam::refusal(seam::Op::Media, "chat_and_id_required", "one message: pass chat and id"));
    };
    let chat = chat.jid();
    let Some(record) = load(store, &chat, id).await? else {
        return Ok(seam::refusal(seam::Op::Media, "not_indexed", "no message with that id in this chat"));
    };
    let mut answer = serde_json::json!({
        "chat": chat,
        "id": id,
        "kind": record.kind,
        "ts": record.ts,
        "sender": record.sender,
        "text": record.snippet(seam::MAX_TEXT_CHARS),
        "deleted": record.deleted,
        "unsupported": record.unsupported,
        "media": record.media.as_ref().map(media_json),
        "place": record.place.as_ref().map(|place| serde_json::json!({
            "lat": place.lat, "lng": place.lng, "name": place.name, "address": place.address, "live": place.live,
        })),
        "contacts": record.contacts.iter().map(|contact| serde_json::json!({
            "name": contact.name, "phones": contact.phones,
        })).collect::<Vec<_>>(),
        "poll": record.poll.as_ref().map(|poll| serde_json::json!({
            "name": poll.name, "options": poll.options, "selectable": poll.selectable,
        })),
    });
    answer["downloadable"] = serde_json::Value::Bool(
        record.media.as_ref().is_some_and(|media| media.downloadable) && !record.deleted && record.unsupported.is_empty(),
    );
    Ok(seam::answer(seam::Op::Media, answer))
}

/// What one `whatsapp_download` needs from the index before a byte is fetched: which chat and message,
/// their media, and the plaintext bound this node will decrypt.
#[derive(Clone, Debug, PartialEq)]
pub struct DownloadTarget {
    pub chat: String,
    pub id: String,
    pub media: record::Media,
    /// The effective bound: the caller's `max_bytes`, capped by the node's own configuration.
    pub limit: u64,
}

/// The index half of `whatsapp_download`.
pub enum DownloadPlan {
    /// Fetch this: the record, its media and the bound.
    Fetch(Box<DownloadTarget>),
    /// Answered: a reason the caller can act on (never indexed, no media, revoked, too large).
    Refused(serde_json::Value),
}

/// The query half of `whatsapp_download`: everything that can be decided from the index, in the order
/// the caller reads it. The guest owns the other half (client, decryption, progress chunks), so a chat
/// this refuses is a refusal before any network work - and this half is pure, which is what lets a
/// test ask it the same question the node asks without a WhatsApp connection. A refusal is
/// `Ok(Refused(answer))`; only a store failure is `Err(reason)`, and the queue retries those.
pub async fn download_plan<S: Store>(store: &S, request: &seam::Verified, node_max: u64) -> Result<DownloadPlan, String> {
    let (Some(chat), Some(id)) = (&request.chat, &request.id) else {
        return Ok(DownloadPlan::Refused(seam::refusal(seam::Op::Download, "chat_and_id_required", "one message: pass chat and id")));
    };
    // The chat the request names, in the canonical spelling the writer stored it under: `Chat::jid` is
    // the same normalisation `chat::storable` applies on the write side (`c.us` -> `s.whatsapp.net`),
    // so a chat a caller names and a chat the index keys agree by construction.
    let chat = chat.jid();
    let id = id.clone();
    let Some(record) = load(store, &chat, &id).await? else {
        return Ok(DownloadPlan::Refused(seam::refusal(seam::Op::Download, "not_indexed", "no message with that id in this chat")));
    };
    if record.deleted {
        return Ok(DownloadPlan::Refused(seam::refusal(seam::Op::Download, "deleted", "the message was revoked; its media is gone")));
    }
    let Some(media) = record.media.clone() else {
        return Ok(DownloadPlan::Refused(seam::refusal(seam::Op::Download, "no_media", "this message carries no media")));
    };
    if !media.downloadable || !record.unsupported.is_empty() {
        return Ok(DownloadPlan::Refused(seam::refusal(
            seam::Op::Download,
            "not_downloadable",
            "this media cannot be fetched (view-once, or the keys were not kept)",
        )));
    }
    let limit = request.max_bytes.min(node_max);
    if media.size > limit {
        let mut answer = seam::refusal(seam::Op::Download, "download_too_large", "the media is larger than this node will decrypt");
        answer["size"] = serde_json::Value::from(media.size);
        answer["max_bytes"] = serde_json::Value::from(limit);
        return Ok(DownloadPlan::Refused(answer));
    }
    Ok(DownloadPlan::Fetch(Box::new(DownloadTarget { chat, id, media, limit })))
}

/// The reactions folded onto one message, bounded and newest first.
async fn fold_reactions<S: Store>(store: &S, chat: &str, target: &str) -> Result<Vec<serde_json::Value>, String> {
    let rows = fold_reactions_rows(store, chat, target).await?;
    Ok(rows
        .iter()
        .take(MAX_FOLDED)
        .map(|row| serde_json::json!({"sender": row.sender, "name": row.name, "emoji": row.emoji, "ts": row.ts, "own": row.own}))
        .collect())
}

#[derive(Clone, Debug, Default, serde::Serialize, serde::Deserialize)]
#[serde(default)]
struct ReactionRow {
    sender: String,
    name: String,
    emoji: String,
    ts: i64,
    own: bool,
}

async fn fold_reactions_rows<S: Store>(store: &S, chat: &str, target: &str) -> Result<Vec<ReactionRow>, String> {
    let prefix = reaction_prefix(chat, target);
    let page = store.scan(prefix.as_bytes(), None, 64).await?;
    let mut rows: Vec<ReactionRow> = page
        .into_iter()
        .filter_map(|(_, value)| serde_json::from_slice::<ReactionRow>(&value).ok())
        .collect();
    rows.sort_by(|a, b| b.ts.cmp(&a.ts).then_with(|| a.sender.cmp(&b.sender)));
    Ok(rows)
}

fn emoji_tally(rows: &[ReactionRow]) -> serde_json::Value {
    let mut counts: std::collections::BTreeMap<String, u32> = std::collections::BTreeMap::new();
    for row in rows {
        *counts.entry(row.emoji.clone()).or_insert(0) += 1;
    }
    let mut out = serde_json::Map::new();
    for (emoji, count) in counts {
        out.insert(emoji, serde_json::Value::from(count));
    }
    serde_json::Value::Object(out)
}

/// Where a `read` starts: `<before>` is a message id in that chat, or an epoch.
async fn before_cursor<S: Store>(store: &S, chat: &str, before: &str) -> Result<Vec<u8>, String> {
    let ts = match before.parse::<i64>() {
        Ok(value) => record_of_epoch(value),
        Err(_) => match load(store, chat, before).await? {
            Some(record) => record_of_epoch(record.ts),
            // An id this chat never had: the cursor is the newest message, which is an honest empty
            // answer instead of "everything".
            None => {
                // An id this chat never had: start after everything, which is an honest empty answer
                // instead of "everything".
                let mut cursor = format!("{PREFIX}m/{chat}/").into_bytes();
                cursor.push(0xff);
                return Ok(cursor);
            }
        },
    };
    // A cursor is exclusive on the whole key, so it has to sort *after* `<inv>/<id>` and before
    // `<inv+1>/…`: a raw 0xFF byte is greater than any byte an id can contain.
    let mut cursor = format!("{PREFIX}m/{chat}/{}/", inv(ts)).into_bytes();
    cursor.push(0xff);
    Ok(cursor)
}

fn record_of_epoch(value: i64) -> i64 {
    if value.abs() < 100_000_000_000 {
        value.saturating_mul(1000)
    } else {
        value
    }
}

/// Does this record pass the filters that are not the free text?
fn matches(record: &Record, request: &seam::Verified) -> bool {
    if let Some(chat) = &request.chat {
        if record.chat != chat.jid() {
            return false;
        }
    }
    if let Some(kind) = &request.kind {
        if &record.kind != kind {
            return false;
        }
    }
    if let Some(from) = &request.from {
        if !same_user(&record.sender, &from.jid()) && !same_user(&record.sender_alt, &from.jid()) {
            return false;
        }
    }
    if let Some(since) = request.since {
        if record.ts < since {
            return false;
        }
    }
    if let Some(until) = request.until {
        if record.ts > until {
            return false;
        }
    }
    true
}

/// Two JIDs of the same person: same user part and same server, ignoring a device or an alias form.
fn same_user(a: &str, b: &str) -> bool {
    let bare = |jid: &str| {
        let (user, server) = jid.split_once('@')?;
        Some(format!("{}@{server}", user.split(':').next()?))
    };
    match (bare(a), bare(b)) {
        (Some(a), Some(b)) => a == b,
        _ => false,
    }
}

/// How good a hit is. The intersection already says every token matched; this ranks *how*: an exact
/// phrase beats scattered words, a filename or a transcript hit is called out, and a newer message
/// wins a tie (the caller is usually asking about something recent).
fn score(record: &Record, tokens: &[String], q: Option<&str>) -> i64 {
    let mut score = 0i64;
    let hay = record::fold(&record.searchable());
    // "The message said this" beats "a file is named this": the phrase bonus is about the words the
    // sender wrote (or that a transcript/OCR pass recovered), never about a filename.
    let words = record::fold(&format!("{} {} {}", record.text, record.transcript, record.ocr));
    if let Some(q) = q {
        let needle = record::fold(q);
        let needle = needle.trim();
        if !needle.is_empty() && words.contains(needle) {
            score += 60;
        }
    }
    if !tokens.is_empty() {
        let present = tokens.iter().filter(|token| hay.contains(token.as_str())).count();
        score += 40 * present as i64 / tokens.len() as i64;
    }
    if let Some(media) = &record.media {
        let name = record::fold(&media.filename);
        if !name.is_empty() && tokens.iter().any(|token| name.contains(token.as_str())) {
            score += 15;
        }
    }
    if !record.transcript.is_empty() || !record.ocr.is_empty() {
        let text = record::fold(&format!("{} {}", record.transcript, record.ocr));
        if tokens.iter().any(|token| text.contains(token.as_str())) {
            score += 15;
        }
    }
    // A message the sender deleted is still a fact, but it is never the best answer to a text search.
    if record.deleted {
        score -= 50;
    }
    score
}

/// The answer's shape for one record: enough to recognise the message, never the whole of it.
///
/// It is [`crate::view::message`] - the same object a thread read carries, so a hit and a bubble cannot
/// describe one message two ways - plus the two things only a search knows: the score, and the name of
/// the chat it was found in (a hit that says `5519…@s.whatsapp.net` makes a reader ask who that is).
fn hit_json(record: &Record, score: i64, chat_name: &str) -> serde_json::Value {
    let mut hit = crate::view::message(record, None);
    hit["own"] = serde_json::Value::Bool(record.own);
    if !chat_name.is_empty() {
        hit["chat_name"] = serde_json::Value::String(chat_name.to_string());
    }
    if score != 0 {
        hit["score"] = serde_json::Value::from(score);
    }
    // The keys the earlier shape carried and a reader may still hold.
    if !record.quoted.is_empty() {
        hit["quoted"] = serde_json::Value::String(record.quoted.clone());
    }
    if let Some(media) = &record.media {
        // A hit keeps the plaintext hash a caller quotes to a download; the view is metadata only.
        let mut meta = media_json(media);
        meta["name"] = serde_json::Value::String(media.filename.clone());
        meta["caption"] = serde_json::Value::String(record.text.clone());
        hit["media"] = meta;
    }
    if !record.transcript.is_empty() {
        hit["transcript"] = serde_json::Value::String(record::one_line(&record.transcript, seam::MAX_TEXT_CHARS));
    }
    if !record.ocr.is_empty() {
        hit["ocr"] = serde_json::Value::String(record::one_line(&record.ocr, seam::MAX_TEXT_CHARS));
    }
    hit
}

/// The media metadata an answer carries: no media key, no direct path (they are how the component
/// decrypts, not something a model needs to see).
fn media_json(media: &record::Media) -> serde_json::Value {
    let mut out = serde_json::json!({
        "kind": media.kind,
        "mime": media.mime,
        "filename": media.filename,
        "size": media.size,
        "sha256": media.sha256,
        "downloadable": media.downloadable,
    });
    if media.duration_s > 0 {
        out["duration_s"] = serde_json::Value::from(media.duration_s);
    }
    if media.pages > 0 {
        out["pages"] = serde_json::Value::from(media.pages);
    }
    if media.width > 0 || media.height > 0 {
        out["width"] = serde_json::Value::from(media.width);
        out["height"] = serde_json::Value::from(media.height);
    }
    if media.animated {
        out["animated"] = serde_json::Value::Bool(true);
    }
    if media.view_once {
        out["view_once"] = serde_json::Value::Bool(true);
    }
    out
}

// ---- retention -----------------------------------------------------------------------------------

/// How long the index keeps a message, in days, and the floor it may be shrunk to under storage
/// pressure.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Retention {
    pub days: u32,
}

impl Retention {
    pub fn new(days: u32) -> Retention {
        // Below a day the index answers "what did they just say" and nothing else; above ten years it
        // is a backup nobody asked for. Both ends are clamps, not refusals: a config typo must not stop
        // the index from running.
        Retention { days: days.clamp(1, 3650) }
    }

    pub fn cutoff(&self, now_ms: i64) -> i64 {
        now_ms - i64::from(self.days) * 86_400_000
    }
}

/// What one prune pass did. `more` means "there is more stale work": the caller runs another pass.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Pruned {
    pub records: usize,
    pub more: bool,
    /// How many archived months the pass walked past without deleting anything in them: a month loaded
    /// back from its archive is read-only here, and its records are older than the window by
    /// construction (`docs/WHATSAPP-ARCHIVE.md`).
    pub restored_months: usize,
}

/// Delete records older than the retention window, oldest first, at most `budget` of them.
///
/// Walking `ix/all` (age order) means the pass stops at the first record inside the window, so it costs
/// what it deletes and not what the index holds. It is incremental on purpose: a phone that wakes up
/// after a month away must not spend a minute deleting in one tick.
pub async fn prune<S: Store>(store: &S, now_ms: i64, retention: Retention, budget: usize) -> Result<Pruned, String> {
    let cutoff = retention.cutoff(now_ms);
    let mut pruned = Pruned::default();
    let mut cursor: Option<Vec<u8>> = None;
    let prefix = format!("{PREFIX}all/");
    // The months loaded back from an archive, as ranges. A restored month is older than the window by
    // construction, so it sits exactly where this pass deletes; skipping its range is what keeps a
    // restore from being undone by the next tick, and it costs one scan of `ix/arc/` per pass instead
    // of one read per restored record.
    let restored = restored_ranges(store).await?;
    'walk: loop {
        let page = store.scan(prefix.as_bytes(), cursor.clone(), PAGE).await?;
        if page.is_empty() {
            return Ok(pruned);
        }
        cursor = page.last().map(|(key, _)| key.clone());
        let short = page.len() < PAGE;
        for (key, _) in page {
            let text = String::from_utf8_lossy(&key).into_owned();
            let rest = text.strip_prefix(&prefix).unwrap_or_default();
            let parts: Vec<&str> = rest.split('/').collect();
            if parts.len() != 3 {
                continue;
            }
            let Some(ts) = from_age(parts[0]) else { continue };
            if let Some(end) = restored.iter().find(|(start, end)| ts >= *start && ts < *end).map(|(_, end)| *end) {
                // Everything left in this range belongs to an archived month: nothing here is this
                // pass's to delete. Continue after the range instead of reading it page by page.
                pruned.restored_months += 1;
                cursor = Some(jump_key(end));
                continue 'walk;
            }
            if ts >= cutoff {
                // Everything after this key is newer still: the window is intact from here on.
                return Ok(pruned);
            }
            if pruned.records >= budget {
                pruned.more = true;
                return Ok(pruned);
            }
            let (chat, id) = (parts[1], parts[2]);
            if let Some(record) = load(store, chat, id).await? {
                remove(store, &record).await?;
                for (key, _) in store.scan(reaction_prefix(chat, id).as_bytes(), None, 64).await? {
                    store.del(&key).await?;
                }
            }
            // The age key goes last: a crash between the two leaves a record without its age entry,
            // which is a leak the next `repair` finds, never a record deleted twice.
            store.del(key.as_slice()).await?;
            pruned.records += 1;
        }
        if short {
            return Ok(pruned);
        }
        if pruned.records >= budget {
            pruned.more = true;
            return Ok(pruned);
        }
    }
}

/// Rebuild what a crash can leave out of step: an age key whose record is gone, a record with no age
/// key, and a token/sender/kind key whose record vanished. Bounded by `budget` entries per call.
pub async fn repair<S: Store>(store: &S, budget: usize) -> Result<usize, String> {
    let mut fixed = 0usize;
    // Records with no age key still belong to the thread. `ix/m` is the record store, so walking it
    // finds them; the pass is bounded and resumes next call (it always starts at the newest, which is
    // the cheapest place to be wrong).
    let mut cursor: Option<Vec<u8>> = None;
    let prefix = format!("{PREFIX}m/");
    while fixed < budget {
        let page = store.scan(prefix.as_bytes(), cursor.clone(), PAGE).await?;
        if page.is_empty() {
            break;
        }
        cursor = page.last().map(|(key, _)| key.clone());
        let short = page.len() < PAGE;
        for (_, value) in page {
            let Ok(record) = serde_json::from_slice::<Record>(&value) else { continue };
            let age_key = key_age(record.ts, &record.chat, &record.id);
            if store.get(age_key.as_bytes()).await?.is_none() {
                store.set(age_key.as_bytes(), source_word(&record).as_bytes()).await?;
                fixed += 1;
                if fixed >= budget {
                    break;
                }
            }
        }
        if short {
            break;
        }
    }
    Ok(fixed)
}

/// The tokens of one text, as this module indexes them (the tests use it to assert the token keys).
pub fn tokens_of(text: &str) -> BTreeSet<String> {
    record::tokenize(text).into_iter().take(MAX_TOKENS).collect()
}

#[cfg(test)]
mod op_contract {
    use super::{seam, OPS};

    /// The component answers every question the seam can carry - no more, no fewer.
    ///
    /// This is the contract between the node that enqueues a query and the component that settles it,
    /// asserted from the component's side on purpose: the host has its own half
    /// (`rust/wa-capabilities/src/whatsapp_query.rs`, every `seam::Op` has a `host.whatsapp_<op>`), and
    /// a disagreement between the two is what dead-letters a job the caller expected an answer to
    /// (measured 13/11: `contacts` on the account node answered `bad_op`, retried, and dead-lettered).
    #[test]
    fn the_component_answers_every_op_the_seam_defines() {
        assert_eq!(OPS, seam::Op::ALL, "the worker's op list and the seam's differ");
        for op in seam::Op::ALL {
            assert!(OPS.contains(&op), "this component does not answer {op:?}");
            assert_eq!(seam::Op::parse(op.as_str()), Some(op), "{op:?} does not round-trip from its own name");
            assert_eq!(seam::Op::parse_tool(op.tool()), Some(op), "{op:?} does not round-trip from its tool name");
        }
    }

    /// The `bad_op` sentence names every op, so a refusal quotes the rule it enforces.
    ///
    /// Measured 13/11: it still read "search, read, message, reactions, media, download or backfill" a
    /// day after `contacts` landed, so the refusal that named the caller's mistake left out the op the
    /// caller had just used.
    #[test]
    fn the_bad_op_refusal_lists_every_op() {
        let refusal = seam::Request { op: "contacts_v2".into(), ..seam::Request::default() }
            .validate()
            .expect_err("an unknown op is refused");
        assert_eq!(refusal.code, "bad_op");
        for op in seam::Op::ALL {
            assert!(
                refusal.detail.contains(op.as_str()),
                "the refusal names no {op:?}: {}",
                refusal.detail
            );
        }
    }
}

#[cfg(test)]
mod tests;
