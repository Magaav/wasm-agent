//! The inventory itself: the one capability that publishes these rows as JSON, the document
//! wa capabilities --json, the sandbox and /health all read. The handler is in
//! crate::capabilities.
//!
//! One file per area, and this file is the whole registration of its capabilities: build.rs scans
//! this directory (src/registry_scan.rs) and capabilities::registry() is built from what it finds,
//! so adding or moving a capability edits this file and nothing else. docs/HOST.md keeps one
//! documented row per capability, which the drift test in capabilities checks against these rows.

use crate::capabilities::plain;

pub const ROWS: &[crate::capabilities::Capability] = &[
    plain!("capability_inventory", ReadOnly, crate::capabilities::inventory_capability, "List every host capability as JSON: name, one-line description and effect class"),
];
