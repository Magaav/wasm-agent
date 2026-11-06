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
//! * **Bounded, and it says so.** One blob may carry tens of thousands of messages. A drain stops at
//!   the first budget it hits - per chat, in total, or per notification - and reports which one, so
//!   the rest is a smaller answer and never a starved component. The counters come from one bounded
//!   pass over the index's age keys (`index::age_index`), not from a maintained counter that drifts.
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
use std::collections::BTreeMap;
use wa_whatsapp_index as seam;
use whatsapp_rust::waproto::whatsapp as wap;

/// Most index entries one budget pass may read to count what is already backfilled.
///
/// The index is bounded by the component's storage grant and by retention; this is the ceiling on what
/// one history notification costs to *plan*, so a huge index slows a drain down instead of stopping
/// the component. A capped pass under-counts, which makes the budget stricter, never looser.
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

/// How much of the past one component will hold. Every field is a count, because a count is what a
/// budget can be measured against; the storage grant is the byte-level wall behind them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Budget {
    /// Most backfilled records one chat may hold.
    pub per_chat: usize,
    /// Most backfilled records the index may hold in total.
    pub total: usize,
    /// Most records one history notification may add, so a large sync is spread over ticks.
    pub per_sync: usize,
}

impl Default for Budget {
    fn default() -> Budget {
        // A phone's initial bootstrap can carry a whole account; these defaults keep the component's
        // storage inside a normal grant while covering a conversation's recent past.
        Budget { per_chat: 200, total: 2_000, per_sync: 1_000 }
    }
}

impl Budget {
    /// Read the service definition's `index_history*` keys. Absent keys are the defaults; a value of
    /// zero means "off" for that dimension (which is a decision, not a typo).
    pub fn from_json(config: &serde_json::Value) -> Budget {
        let default = Budget::default();
        Budget {
            per_chat: config["index_history_per_chat"].as_u64().unwrap_or(default.per_chat as u64) as usize,
            total: config["index_history_total"].as_u64().unwrap_or(default.total as u64) as usize,
            per_sync: config["index_history_per_sync"].as_u64().unwrap_or(default.per_sync as u64) as usize,
        }
    }

    /// Nothing may be backfilled: `index_history: false` is the same budget as every count at zero.
    pub fn off() -> Budget {
        Budget { per_chat: 0, total: 0, per_sync: 0 }
    }

    pub fn is_off(&self) -> bool {
        self.per_chat == 0 || self.total == 0 || self.per_sync == 0
    }
}

/// Why a drain stopped early.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Stop {
    /// This chat already holds `per_chat` backfilled records.
    PerChat,
    /// The index already holds `total` backfilled records.
    Total,
    /// This notification reached `per_sync`; the rest of it is dropped (a new sync, or an on-demand
    /// request, is what fetches more).
    Sync,
    /// A write or a read failed: the store (or the storage grant) is the wall.
    Store,
}

impl Stop {
    pub fn as_str(self) -> &'static str {
        match self {
            Stop::PerChat => "per_chat",
            Stop::Total => "total",
            Stop::Sync => "per_sync",
            Stop::Store => "store",
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
    /// Messages a per-chat or total budget refused.
    pub over_budget: usize,
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
        self.over_budget += other.over_budget;
        self.remaining += other.remaining;
        if self.stopped.is_none() {
            self.stopped = other.stopped;
            self.reason = other.reason;
        }
    }

    /// The service log's line for this drain: counts, a stop reason, and nothing a person said.
    pub fn line(&self) -> String {
        format!(
            "conversations={} seen={} written={} duplicate={} skipped={} over_budget={} remaining={} stopped={}{}",
            self.conversations,
            self.seen,
            self.written,
            self.duplicate,
            self.skipped,
            self.over_budget,
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
            },
            message: info.message.as_option().cloned().unwrap_or_default(),
        });
    }
    out
}

/// What one drain is allowed to add, and what the index already holds.
///
/// Built once per history notification (`Plan::of`): the counting pass is the expensive part of a
/// drain, and a chunked sync carries many conversations that all share the same budget.
pub struct Plan {
    pub budget: Budget,
    /// Backfilled records the index holds, plus what this drain has written.
    pub total: usize,
    /// Backfilled records per chat, plus what this drain has written.
    pub per_chat: BTreeMap<String, usize>,
    /// Records this drain has written.
    pub written: usize,
    /// The counting pass hit its entry budget: the counts are a floor, so the budget is stricter.
    pub capped: bool,
}

impl Plan {
    pub async fn of<S: Store>(store: &S, budget: Budget) -> Result<Plan, String> {
        let index = index::age_index(store, COUNT_CAP).await?;
        Ok(Plan {
            budget,
            total: index.history,
            per_chat: index.chats.iter().map(|entry| (entry.chat.clone(), entry.history)).collect(),
            written: 0,
            capped: index.capped,
        })
    }

    /// How many backfilled records this chat holds (including this drain's writes).
    pub fn held(&self, chat: &str) -> usize {
        self.per_chat.get(chat).copied().unwrap_or(0)
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
        progress.stopped = Some(Stop::Total);
        return progress;
    }
    let candidates = candidates(conversation, me);
    progress.seen = candidates.len();
    for (position, candidate) in candidates.iter().enumerate() {
        if plan.written >= plan.budget.per_sync {
            progress.stopped = Some(Stop::Sync);
            progress.remaining = candidates.len() - position;
            break;
        }
        if plan.total >= plan.budget.total {
            progress.stopped = Some(Stop::Total);
            progress.remaining = candidates.len() - position;
            break;
        }
        let chat = candidate.envelope.chat.as_str();
        if plan.held(chat) >= plan.budget.per_chat {
            progress.over_budget += 1;
            continue;
        }
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
                plan.total += 1;
                *plan.per_chat.entry(chat.to_string()).or_insert(0) += 1;
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
