//! The speech queue (docs/QUEUE.md, Phase 2): the producing node's peer call, the operator surface,
//! and the two halves of the worker's pump. The handlers are in crate::stt.
//!
//! One file per area, and this file is the whole registration of its capabilities: build.rs scans
//! this directory (src/registry_scan.rs) and capabilities::registry() is built from what it finds,
//! so adding or moving a capability edits this file and nothing else. docs/HOST.md keeps one
//! documented row per capability, which the drift test in capabilities checks against these rows.

use crate::capabilities::plain;

pub const ROWS: &[crate::capabilities::Capability] = &[
    // One capability per thing the Lua side does: the producing node answers a peer's call, an
    // operator submits or reads the queue, and the worker role borrows the two halves of a pump.
    plain!("stt_call", WritesFiles, crate::stt::call, "One admitted stt.requests call from a peer node (take/audio/beat/seg/done/fail): the producing node's queue, its lease rule and its audio"),
    plain!("stt_submit", WritesFiles, crate::stt::submit, "Enqueue one note on stt.requests with its chat/message ids and send time; the freshness window starts at the send time"),
    plain!("stt_admin", WritesFiles, crate::stt::admin, "The speech queue's operator surface: configure the node's producer/worker role, status (attached workers, latency, local vs remote counts), one job's state, a sweep"),
    plain!("stt_pending", ReadOnly, crate::stt::pending, "The next signed stt.requests call the worker thread wants sent (null when idle), for the node's Lua pump"),
    plain!("stt_deliver", ReadOnly, crate::stt::deliver, "Deliver one peer answer to the waiting worker thread and return the next pending call"),
];
