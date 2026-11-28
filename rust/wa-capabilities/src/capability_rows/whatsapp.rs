//! WhatsApp (docs/SERVICE-COMPONENTS.md, docs/GRANT-POLICY.md): one capability per effect - a send
//! that queues on whatsapp.outbox after the policy check, the operator's approval gate, and the
//! index and archive queries. The handlers are in crate::whatsapp_send, crate::whatsapp_approve,
//! crate::whatsapp_query and crate::whatsapp_archive.
//!
//! One file per area, and this file is the whole registration of its capabilities: build.rs scans
//! this directory (src/registry_scan.rs) and capabilities::registry() is built from what it finds,
//! so adding or moving a capability edits this file and nothing else. docs/HOST.md keeps one
//! documented row per capability, which the drift test in capabilities checks against these rows.

use crate::capabilities::plain;

pub const ROWS: &[crate::capabilities::Capability] = &[
    // One capability per effect: `whatsapp_send` asks the node's `whatsapp.send` policy and enqueues
    // a job on `wa:queue`; `whatsapp_send_status` reads the job back. Neither carries message text
    // out in its answer.
    plain!("whatsapp_send", Network, crate::whatsapp_send::capability, "Send one WhatsApp message to an exact chat JID through the durable whatsapp.outbox queue, after the whatsapp.send policy check; returns the job id"),
    plain!("whatsapp_send_status", ReadOnly, crate::whatsapp_send::status_capability, "State of one queued WhatsApp send: queued, sending, done with its message id, or failed with a reason"),
    // The operator's gate on the same send (docs/APPROVE.md): while approval is on for a chat,
    // `whatsapp_send` queues nothing and answers a draft instead, and this capability is how a reader
    // sees the drafts waiting and decides one. `network` because a decision enqueues a send.
    plain!("whatsapp_approve", Network, crate::whatsapp_approve::capability, "List, read and decide the WhatsApp drafts waiting for operator approval; a decision enqueues the send, a rejection queues nothing"),
    // The message index the component keeps: one capability per question, all of them a job on
    // `whatsapp.query` (read-only, so no policy rule and no rate limit of their own).
    plain!("whatsapp_search", ReadOnly, crate::whatsapp_query::search, "Search indexed WhatsApp messages by text (accent-folded), chat, kind, sender or time window; returns matching records with snippets"),
    plain!("whatsapp_read", ReadOnly, crate::whatsapp_query::read, "Read one WhatsApp chat newest-first (an exact JID or a name), with reactions folded onto the messages they answer, a header naming the chat and a cursor for the older page"),
    plain!("whatsapp_contacts", ReadOnly, crate::whatsapp_query::contacts, "Which chats this index knows, by the name it observed: push names, group subjects and the chat's own digits, best match first, with the candidates when a name is ambiguous"),
    plain!("whatsapp_message", ReadOnly, crate::whatsapp_query::message, "One exact WhatsApp message by chat and id, with its full stored text - what an exact reply source and a sent-message echo are compared against"),
    plain!("whatsapp_reactions", ReadOnly, crate::whatsapp_query::reactions, "Who reacted to one WhatsApp message, with which emoji"),
    plain!("whatsapp_media", ReadOnly, crate::whatsapp_query::media, "The media metadata of one WhatsApp message: mime, filename, size, sha256, duration, pages"),
    // One row for every read-only question a component can grow on its own: the op travels in the
    // request (`{op, ...args}`), so a new read answer needs no host change and this list stops being
    // a place a WhatsApp change lands (2026-11-25, "WhatsApp leaves the host"). ReadOnly, because
    // every op it can carry is: the effect class is what the sandbox joins and serializes on.
    plain!("whatsapp_index", ReadOnly, crate::whatsapp_query::index, "Ask the WhatsApp index one read-only question the wa-whatsapp component knows: {op, ...args}, op being search, read, contacts, message, reactions or media; the answer is the one whatsapp_<op> gives"),
    plain!("whatsapp_download", WritesFiles, crate::whatsapp_query::download, "Decrypt one WhatsApp message's media into this node's bounded download folder and return the path"),
    // The third class, the same shape: the questions whose answer is a file this node writes ({op,
    // ...args}, today `download`). `WritesFiles` is what a sandbox must not join as a read.
    plain!("whatsapp_file", WritesFiles, crate::whatsapp_query::file, "Ask the wa-whatsapp component to write one thing into this node's bounded download folder: {op, ...args}, op being download; the answer is the path, or the one whatsapp_download gives"),
    // The one query that asks the phone: it enqueues on the same `whatsapp.query` queue, and the
    // component's answer is the history request it made (ids and counts), never a message.
    // Retention's other half: the monthly cut into a compressed and sealed archive file, the push to
    // another disk or node, the 360-day expiry, and restore/unload of one month. Master-only and
    // file-writing: it cuts the index the component owns and writes archives to the node's own
    // components directory (`docs/WHATSAPP-ARCHIVE.md`).
    plain!("whatsapp_archive", WritesFiles, crate::whatsapp_archive::capability, "WhatsApp index archives: cut a month that left the window into one sealed file, list, push with its sha256 verified, restore, unload, expire"),
    plain!("whatsapp_backfill", Network, crate::whatsapp_query::backfill, "Ask the primary phone for WhatsApp messages older than the index holds, so a search can reach the account's past"),
    // The same generic door as `whatsapp_index`, declaring the other effect: the ops that ASK THE PHONE
    // ({op, ...args}, today `backfill`). A read must not ride it and a phone request must not ride the
    // read door - `seam::Op::effect` decides, and the refusal names the right row (2026-11-25).
    plain!("whatsapp_request", Network, crate::whatsapp_query::request, "Ask the wa-whatsapp component one question that reaches the phone: {op, ...args}, op being backfill; the answer is the one whatsapp_<op> gives"),
];
