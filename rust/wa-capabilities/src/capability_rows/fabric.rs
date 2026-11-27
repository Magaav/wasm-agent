//! The compute fabric (docs/FABRIC.md): the operator surface, a peer's call, and the two halves of
//! the record pump. The handlers are in crate::fabric.
//!
//! One file per area, and this file is the whole registration of its capabilities: build.rs scans
//! this directory (src/registry_scan.rs) and capabilities::registry() is built from what it finds,
//! so adding or moving a capability edits this file and nothing else. docs/HOST.md keeps one
//! documented row per capability, which the drift test in capabilities checks against these rows.

use crate::capabilities::plain;

pub const ROWS: &[crate::capabilities::Capability] = &[
    // The rules live in `wa-fabric`; these four are the node's own half: configure and read the live
    // view, answer a peer's heartbeat or offer, and pump the records the node must sign.
    plain!("fabric_admin", WritesFiles, crate::fabric::admin, "The compute fabric's operator surface: configure, status (nodes with load, age and capabilities, recent placements with their score, fallbacks by reason, leases), tick, submit/take/settle - ids, numbers and words, never a payload"),
    plain!("fabric_call", WritesFiles, crate::fabric::call, "One admitted fabric call from a peer node: its heartbeat (observed in the live view) or an offer, answered from this node's load right now"),
    plain!("fabric_pending", ReadOnly, crate::fabric::pending, "The next fabric record the node must sign and send (a heartbeat or an offer), or null when there is nothing to say"),
    plain!("fabric_deliver", ReadOnly, crate::fabric::deliver, "Deliver one peer answer to the fabric (accept, refuse, heartbeat or unreachable) and return the next record to send"),
];
