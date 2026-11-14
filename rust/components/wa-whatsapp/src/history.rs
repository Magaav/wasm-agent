//! The past: messages WhatsApp sends as a **history sync**, indexed under a budget, and the on-demand
//! request that asks the primary phone for more.
//!
//! The index (`index.rs`) started life as a record of what arrived while the node was connected, and
//! that is what a query answered: after the component swap a search found only messages received since
//! start, while the account had months of history. The past does reach a linked device - WhatsApp
//! delivers it as `historySync` blobs on (re)link, and answers an explicit per-chat request - so this
//! module is the missing half of the index, not a second index:
//!
//! ```text
//! Event::HistorySync(LazyHistorySync)      whatsapp-rust, one event per blob (chunked: several)
//!   -> HistorySyncStream::next_conversation  one chat at a time, bounded memory
//!   -> candidates(conversation)              envelope + message, exactly what `on_message` builds
//!   -> record::from_message + source=history the same parser as a live message
//!   -> index::put                            the same records, keys and tokens
//! ```
//!
//! Decisions worth naming:
//!
//! * **The id is the dedupe, and the first writer keeps the row.** A message that is already indexed -
//!   live or backfilled - is counted as a duplicate and not written again: a history sync that
//!   re-delivers the last week must not rewrite (or reorder) records a query already answers with,
//!   and must never downgrade a live record's `source` to `history`.
//! * **Bounded by age, and it says so.** One blob may carry tens of thousands of messages. The past
//!   reaches exactly as far back as the live index keeps (`index_retention_days`, one clock), one
//!   notification adds at most `per_sync` records, and a drain stops at the first bound it hits and
//!   reports which one, so the rest is a smaller answer and never a starved component. There is no
//!   per-chat cap and no total cap: a count is a second window that has to be kept in step with the
//!   first by hand, and the operator removed both on 13/11.
//! * **The storage quota is the wall, not a promise.** A failed write stops the drain and is reported
//!   (`Stop::Store`): the component's grant is what bounds the index, so "quota reached" is a stop
//!   with a reason, never a silent loss or a retry into the same wall.
//! * **Nothing here logs and nothing here answers with text.** The counts go to the service log, the
//!   records go to the index, and the on-demand request carries ids and numbers only.
//! * **The past is not the present.** A backfilled message is indexed exactly like a live one (same
//!   kinds, same tokens, same `read`/`search` answers) but marked `source: history`, so a query can
//!   tell the two apart and an operator can see how much of the index is backfill.
use crate::index::{self, Store};
use crate::record::{self, Envelope};
use wa_whatsapp_index as seam;
use whatsapp_rust::waproto::whatsapp as wap;

/// Most index entries one budget pass may read to count what is already backfilled.
///
/// The index is bounded by the component's storage grant and by retention; this is the ceiling on what
/// one age-index pass reads (the one `anchors` does, to find the oldest message of each chat), so a
/// huge index slows a backfill down instead of stopping the component. A capped pass under-counts.
pub const COUNT_CAP: usize = 50_000;

/// Where "we" are, so an own message in a group is attributed to us and not to the chat.
///
/// A live message carries its sender in the envelope; a `WebMessageInfo` from a history sync carries
/// the author only for messages somebody else sent (and only in a group). This is the missing half.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SelfJids {
    /// Our phone-number JID (`5511…@s.whatsapp.net`), when the client knows it.
    pub pn: String,
    /// Our LID (`7210…@lid`), when the account has migrated.
    pub lid: String,
}

impl SelfJids {
    /// The address to record as the sender of one of our own messages: the LID when the account has
    /// one (that is the namespace the phone stores messages under after migration), else the PN.
    pub fn sender(&self) -> &str {
        if !self.lid.is_empty() {
            &self.lid
        } else {
            &self.pn
        }
    }

    /// The other address of the same person, as `sender_alt`: the author proof uses it. Empty when
    /// there is no second address to record.
    pub fn alt(&self) -> &str {
        if self.lid.is_empty() {
            ""
        } else {
            &self.pn
        }
    }
}

/// How much of the past one component will hold, and how much work one tick may do.
///
/// The past is bounded by **one clock**, not by two counters: a backfilled record is kept for as long
/// as the live index keeps one (`index_retention_days`), so a sync can never smuggle in a message the
/// next prune pass would delete, and the two cannot disagree. Until 13/11 this was `per_chat: 200` and
/// `total: 2_000`, which the operator removed ("bound by age only"): a count is a second, invisible
/// window that had to be kept in step with the first by hand.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Budget {
    /// Most records one history notification may add, so a large sync is spread over ticks. It bounds
    /// one tick's WORK, not what the index may hold.
    pub per_sync: usize,
    /// How far back the past may reach: a message whose own timestamp is older than `now - keep_ms` is
    /// not backfilled.
    pub keep_ms: i64,
}

/// The window every node keeps unless its definition says otherwise: 180 days, the same number
/// `index_retention_days` defaults to (`guest.rs`, `docs/SERVICE-COMPONENTS.md`).
pub const DEFAULT_KEEP_DAYS: i64 = 180;

impl Default for Budget {
    fn default() -> Budget {
        // A phone's initial bootstrap can carry a whole account; `per_sync` keeps a large sync from
        // monopolising the pipeline, and the age is the one the live index is pruned by.
        Budget { per_sync: 1_000, keep_ms: DEFAULT_KEEP_DAYS * 86_400_000 }
    }
}

impl Budget {
    /// Read the service definition. `index_history_per_sync` bounds one tick; `index_retention_days`
    /// (the same key the live index is pruned by) bounds the age. A definition that still carries the
    /// removed `index_history_per_chat` / `index_history_total` keys is not refused - it is reported
    /// once at start (`guest::IndexConfig`), because a key that silently stopped meaning anything is a
    /// decision someone made that nothing honours.
    pub fn from_json(config: &serde_json::Value) -> Budget {
        let default = Budget::default();
        let days = config["index_retention_days"].as_u64().unwrap_or(DEFAULT_KEEP_DAYS as u64).clamp(1, 3_650) as i64;
        Budget {
            per_sync: config["index_history_per_sync"].as_u64().unwrap_or(default.per_sync as u64) as usize,
            keep_ms: days * 86_400_000,
        }
    }

    /// Nothing may be backfilled: `index_history: false` is the same budget as every count at zero.
    pub fn off() -> Budget {
        Budget { per_sync: 0, keep_ms: 0 }
    }

    pub fn is_off(&self) -> bool {
        self.per_sync == 0 || self.keep_ms <= 0
    }

    /// The oldest message timestamp this budget still backfills, for `now`.
    pub fn oldest_ms(&self, now: i64) -> i64 {
        now.saturating_sub(self.keep_ms)
    }
}

/// Why a drain stopped early.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Stop {
    /// This notification reached `per_sync`; the rest of it is dropped (a new sync, or an on-demand
    /// request, is what fetches more).
    Sync,
    /// A write or a read failed: the store (or the storage grant) is the wall.
    Store,
    /// History is off for this node (`index_history: false`).
    Off,
}

impl Stop {
    pub fn as_str(self) -> &'static str {
        match self {
            Stop::Sync => "per_sync",
            Stop::Store => "store",
            Stop::Off => "off",
        }
    }
}

/// What one notification (or one conversation of it) did, in counts. Never content.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Progress {
    /// Conversations the notification carried.
    pub conversations: usize,
    /// Messages it offered.
    pub seen: usize,
    /// Records written to the index.
    pub written: usize,
    /// Messages already indexed (live or backfilled): the dedupe.
    pub duplicate: usize,
    /// Messages with no chat, no id, or a chat the index does not follow (status, newsletter).
    pub skipped: usize,
    /// Messages older than the window this budget keeps: seen, refused, and not `skipped` (which is
    /// "not a chat this index follows"), because a reader asking "how much of the past did I get"
    /// needs to tell the two apart.
    pub too_old: usize,
    /// Messages not reached because the drain stopped.
    pub remaining: usize,
    pub stopped: Option<Stop>,
    /// The store's own word for a failure, when `stopped` is [`Stop::Store`]. A code, never text.
    pub reason: String,
}

impl Progress {
    /// Add one conversation's counts to the notification's: a chunked sync is one log line.
    pub fn merge(&mut self, other: Progress) {
        self.conversations += other.conversations;
        self.seen += other.seen;
        self.written += other.written;
        self.duplicate += other.duplicate;
        self.skipped += other.skipped;
        self.too_old += other.too_old;
        self.remaining += other.remaining;
        if self.stopped.is_none() {
            self.stopped = other.stopped;
            self.reason = other.reason;
        }
    }

    /// The service log's line for this drain: counts, a stop reason, and nothing a person said.
    pub fn line(&self) -> String {
        format!(
            "conversations={} seen={} written={} duplicate={} skipped={} too_old={} remaining={} stopped={}{}",
            self.conversations,
            self.seen,
            self.written,
            self.duplicate,
            self.skipped,
            self.too_old,
            self.remaining,
            self.stopped.map(Stop::as_str).unwrap_or("done"),
            if self.reason.is_empty() { String::new() } else { format!(" reason={}", self.reason) },
        )
    }
}

/// One message a history sync offered, as the envelope and message a live delivery would have handed
/// the index. Keeping the pair (instead of a built [`Record`]) means the drain uses
/// [`record::from_message`] - the one parser - for the past as well as the present.
#[derive(Clone, Debug, PartialEq)]
pub struct Candidate {
    pub envelope: Envelope,
    pub message: wap::Message,
}

/// Is this a chat the index follows? The same rule the live path applies: status broadcasts and
/// newsletter (channel) traffic is not a chat.
pub fn followed(chat: &str) -> bool {
    !chat.is_empty() && chat != "status@broadcast" && !chat.ends_with("@newsletter")
}

/// The candidates one conversation offers, in the order the phone sent them.
///
/// The phone numbers its messages by `msgOrderId`; the drain does not depend on that order, because
/// the index keys by timestamp and the dedupe is by id.
pub fn candidates(conversation: &wap::Conversation, me: &SelfJids) -> Vec<Candidate> {
    let conversation_chat = conversation.id.trim();
    if !followed(conversation_chat) {
        return Vec::new();
    }
    let mut out = Vec::with_capacity(conversation.messages.len());
    for entry in &conversation.messages {
        let Some(info) = entry.message.as_option() else { continue };
        let Some(key) = info.key.as_option() else { continue };
        let id = key.id.as_deref().unwrap_or_default().trim();
        if id.is_empty() {
            continue;
        }
        // The key's chat is the truth when it carries one; the conversation's id is the fallback for
        // the syncs that leave it out.
        let key_chat = key.remote_jid.as_deref().unwrap_or_default().trim();
        let chat = if followed(key_chat) { key_chat } else { conversation_chat };
        let own = key.from_me.unwrap_or(false);
        let author = key
            .participant
            .as_deref()
            .or(info.participant.as_deref())
            .unwrap_or_default()
            .trim();
        let (sender, sender_alt) = if own {
            (me.sender().to_string(), me.alt().to_string())
        } else if !author.is_empty() {
            // A group message names its author; in a DM the author is the chat.
            (author.to_string(), String::new())
        } else {
            (chat.to_string(), String::new())
        };
        out.push(Candidate {
            envelope: Envelope {
                chat: chat.to_string(),
                id: id.to_string(),
                sender,
                sender_alt,
                own,
                group: chat.ends_with("@g.us"),
                // The proto's timestamp is in seconds; the index speaks milliseconds.
                ts: info.message_timestamp.unwrap_or(0).saturating_mul(1000) as i64,
                received: 0, // filled by the drain: when *this node* indexed it
                push_name: info.push_name.clone().unwrap_or_default(),
                // A history-sync entry is the one wire shape that carries the business name
                // (`WebMessageInfo.verifiedBizName`): it is the name WhatsApp shows for that account,
                // and the only way a query for `Padaria` finds a bakery nobody saved.
                business: info.verified_biz_name.as_ref().map(|name| name.to_string()).unwrap_or_default(),
            },
            message: info.message.as_option().cloned().unwrap_or_default(),
        });
    }
    out
}

/// What one drain is allowed to add.
///
/// Built once per history notification and shared by every conversation in it: `per_sync` is one
/// tick's work for the whole notification, and the age is the same for all of them.
pub struct Plan {
    pub budget: Budget,
    /// Records this drain has written.
    pub written: usize,
}

impl Plan {
    /// A plan needs nothing from the store: the bound is the age, and the age is a clock. The counting
    /// pass over the index's age keys that this used to need (one bounded scan per notification) went
    /// with the per-chat and total counters.
    pub fn new(budget: Budget) -> Plan {
        Plan { budget, written: 0 }
    }
}

/// Index one conversation from a history sync under `plan`, and say what happened.
///
/// `now_ms` is when this node indexed it: a backfilled record's `received` is not the phone's clock.
pub async fn drain_conversation<S: Store>(
    store: &S,
    conversation: &wap::Conversation,
    me: &SelfJids,
    plan: &mut Plan,
    now_ms: i64,
) -> Progress {
    let mut progress = Progress { conversations: 1, ..Progress::default() };
    if plan.budget.is_off() {
        progress.stopped = Some(Stop::Off);
        return progress;
    }
    let oldest = plan.budget.oldest_ms(now_ms);
    let candidates = candidates(conversation, me);
    progress.seen = candidates.len();
    for (position, candidate) in candidates.iter().enumerate() {
        if plan.written >= plan.budget.per_sync {
            progress.stopped = Some(Stop::Sync);
            progress.remaining = candidates.len() - position;
            break;
        }
        // The age bound, and the only one: the past reaches exactly as far back as the live index
        // keeps, so what a sync adds is what retention will still answer with. A message with no
        // timestamp (0) is not evidence of age and is kept.
        let ts = candidate.envelope.ts;
        if ts > 0 && ts < oldest {
            progress.too_old += 1;
            continue;
        }
        let chat = candidate.envelope.chat.as_str();
        // The dedupe: the id *is* the message, so a message already indexed - live or backfilled - is
        // not written again, and the row it already has keeps its own source.
        match index::holds(store, chat, &candidate.envelope.id).await {
            Ok(true) => {
                progress.duplicate += 1;
                continue;
            }
            Ok(false) => {}
            Err(reason) => {
                progress.stopped = Some(Stop::Store);
                progress.reason = one_word(&reason);
                progress.remaining = candidates.len() - position;
                break;
            }
        }
        let mut record = record::from_message(&candidate.envelope, &candidate.message);
        record.source = record::SOURCE_HISTORY.to_string();
        record.received = now_ms;
        match index::put(store, &record).await {
            Ok(()) => {
                progress.written += 1;
                plan.written += 1;
            }
            Err(reason) => {
                // The storage grant, or the store itself: stop rather than retry into the same wall.
                progress.stopped = Some(Stop::Store);
                progress.reason = one_word(&reason);
                progress.remaining = candidates.len() - position;
                break;
            }
        }
    }
    progress
}

/// One on-demand history request: the chat, the anchor the phone needs, and how many messages.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Anchor {
    pub chat: String,
    /// The oldest message the index holds for this chat; empty when it holds none, which asks the
    /// phone for the newest messages it has.
    pub id: String,
    pub ts: i64,
    /// Whether the anchor message was ours (the phone needs it to find the message in its own store).
    pub from_me: bool,
    pub count: u32,
}

impl Anchor {
    pub fn to_seam(&self) -> seam::BackfillChat {
        seam::BackfillChat {
            chat: self.chat.clone(),
            count: self.count,
            oldest_id: self.id.clone(),
            oldest_ts: self.ts,
        }
    }
}

/// The anchors a `whatsapp_backfill` asks from: one chat when the caller named one, else the chats the
/// index knows, most recently active first, at most [`seam::BACKFILL_MAX_CHATS`] of them.
///
/// A chat the index has never seen still gets an anchor (empty id): the phone answers with its newest
/// messages, which is the only sensible reading of "go back in a chat I have nothing from".
pub async fn anchors<S: Store>(store: &S, chat: Option<&str>, count: u32) -> Result<Vec<Anchor>, String> {
    let index = index::age_index(store, COUNT_CAP).await?;
    let count = count.clamp(1, seam::BACKFILL_MAX);
    let chosen: Vec<index::ChatAge> = match chat {
        Some(chat) => match index.chat(chat) {
            Some(entry) => vec![entry.clone()],
            None => vec![index::ChatAge { chat: chat.to_string(), ..index::ChatAge::default() }],
        },
        None => index.chats.iter().take(seam::BACKFILL_MAX_CHATS).cloned().collect(),
    };
    let mut out = Vec::with_capacity(chosen.len());
    for entry in chosen {
        // Whether the anchor is ours is a fact about one record, so it is one load - never a scan.
        let from_me = match entry.oldest_id.is_empty() {
            true => false,
            false => index::load(store, &entry.chat, &entry.oldest_id).await?.map(|record| record.own).unwrap_or(false),
        };
        out.push(Anchor { chat: entry.chat, id: entry.oldest_id, ts: entry.oldest_ts, from_me, count });
    }
    Ok(out)
}

/// A store's failure as one word for a log line: never a path, never a value.
fn one_word(reason: &str) -> String {
    reason
        .chars()
        .take(64)
        .map(|ch| if ch.is_ascii_alphanumeric() || matches!(ch, '_' | '-' | ':' | ' ') { ch } else { '_' })
        .collect::<String>()
        .trim()
        .to_string()
}

#[cfg(test)]
mod tests;
