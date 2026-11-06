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
use std::collections::{BTreeSet, HashSet};
use wa_whatsapp_index as seam;

/// Every key this module owns starts here (the component's `kv.write` policy rules it as `ix/*`).
pub const PREFIX: &str = "ix/";
/// Most token keys one record writes. A long document's caption is not a thesaurus.
pub const MAX_TOKENS: usize = 48;
/// How many candidates one narrowing may collect before the answer is "narrow it down".
const CANDIDATE_BUDGET: usize = 2_000;
/// How many records a search may load to rank them.
const LOAD_BUDGET: usize = 400;
/// Page size for a scan.
const PAGE: usize = 200;
/// Most reactions folded onto one message in an answer.
const MAX_FOLDED: usize = seam::MAX_LISTED;

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

fn from_age(text: &str) -> Option<i64> {
    u64::from_str_radix(text, 16).ok().and_then(|value| i64::try_from(value).ok())
}

fn key_message(chat: &str, ts: i64, id: &str) -> String {
    format!("{PREFIX}m/{chat}/{}/{id}", inv(ts))
}

fn key_id(chat: &str, id: &str) -> String {
    format!("{PREFIX}id/{chat}/{id}")
}

fn key_age(ts: i64, chat: &str, id: &str) -> String {
    format!("{PREFIX}all/{}/{chat}/{id}", age(ts))
}

fn key_sender(sender: &str, ts: i64, id: &str, chat: &str) -> String {
    format!("{PREFIX}s/{sender}/{}/{id}/{chat}", inv(ts))
}

fn key_kind(kind: &str, ts: i64, id: &str, chat: &str) -> String {
    format!("{PREFIX}k/{kind}/{}/{id}/{chat}", inv(ts))
}

fn key_token(token: &str, ts: i64, id: &str, chat: &str) -> String {
    format!("{PREFIX}w/{token}/{}/{id}/{chat}", inv(ts))
}

fn key_reaction(chat: &str, target: &str, reactor: &str, emoji: &str) -> String {
    format!("{PREFIX}x/{chat}/{target}/{reactor}/{emoji}")
}

fn reaction_prefix(chat: &str, target: &str) -> String {
    format!("{PREFIX}x/{chat}/{target}/")
}

fn key_pending(chat: &str, id: &str) -> String {
    format!("{PREFIX}pend/{chat}/{id}")
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
    write(store, &record).await
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
    store.del(key_id(&record.chat, &record.id).as_bytes()).await?;
    store.del(key_age(record.ts, &record.chat, &record.id).as_bytes()).await?;
    store.del(key_sender(&record.sender, record.ts, &record.id, &record.chat).as_bytes()).await?;
    store.del(key_kind(&record.kind, record.ts, &record.id, &record.chat).as_bytes()).await?;
    for token in record.tokens() {
        store.del(key_token(&token, record.ts, &record.id, &record.chat).as_bytes()).await?;
    }
    Ok(())
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
    for candidate in list {
        let Some(record) = load(store, &candidate.chat, &candidate.id).await? else { continue };
        if !matches(&record, request) {
            continue;
        }
        let score = score(&record, &tokens, request.q.as_deref());
        hits.push((score, hit_json(&record, score)));
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
pub async fn read<S: Store>(store: &S, request: &seam::Verified) -> Result<serde_json::Value, String> {
    let Some(chat) = &request.chat else {
        return Ok(seam::refusal(seam::Op::Read, "chat_required", "read needs the exact chat JID"));
    };
    let chat = chat.jid();
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
            let mut message = hit_json(&record, 0);
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
    Ok(seam::answer(
        seam::Op::Read,
        serde_json::json!({
            "chat": chat,
            "messages": messages,
            "count": messages.len(),
            "has_more": has_more,
            "next_before": next_before,
            "limit": request.limit,
        }),
    ))
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
fn hit_json(record: &Record, score: i64) -> serde_json::Value {
    let mut hit = serde_json::json!({
        "chat": record.chat,
        "id": record.id,
        "ts": record.ts,
        "sender": record.sender,
        "sender_name": record.push_name,
        "kind": record.kind,
        "text": record.snippet(seam::MAX_TEXT_CHARS),
        "own": record.own,
    });
    if score != 0 {
        hit["score"] = serde_json::Value::from(score);
    }
    if !record.quoted.is_empty() {
        hit["quoted"] = serde_json::Value::String(record.quoted.clone());
    }
    if !record.mentions.is_empty() {
        hit["mentions"] = serde_json::Value::Array(
            record.mentions.iter().take(seam::MAX_LISTED).map(|jid| serde_json::Value::String(jid.clone())).collect(),
        );
    }
    if let Some(media) = &record.media {
        hit["media"] = media_json(media);
    }
    if record.kind == "reaction" && !record.emoji.is_empty() {
        hit["emoji"] = serde_json::Value::String(record.emoji.clone());
        hit["target"] = serde_json::Value::String(record.target.clone());
    }
    if record.kind == "edit" || record.kind == "delete" {
        hit["target"] = serde_json::Value::String(record.target.clone());
    }
    if record.edited {
        hit["edited"] = serde_json::Value::Bool(true);
    }
    if record.deleted {
        hit["deleted"] = serde_json::Value::Bool(true);
    }
    if !record.unsupported.is_empty() {
        hit["unsupported"] = serde_json::Value::String(record.unsupported.clone());
    }
    // Where the record came from: a backfilled message answers a query exactly like a live one, and
    // this is the one field that says it came out of a history sync (`docs/WHATSAPP-TRANSCRIPTION.md`).
    if record.from_history() {
        hit["source"] = serde_json::Value::String(record::SOURCE_HISTORY.to_string());
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
    loop {
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
mod tests;
