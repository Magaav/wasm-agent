//! The provider's rolling limits: the door that reads them off the turn. The handlers are in
//! crate::limits (the state machine and its thread) and crate::host (the Lua bindings).
//!
//! One file per area, and this file is the whole registration of its capabilities: build.rs scans
//! this directory (src/registry_scan.rs) and capabilities::registry() is built from what it finds.

use crate::capabilities::plain;

pub const ROWS: &[crate::capabilities::Capability] = &[
    plain!("limits_start", Network, crate::host::limits_start, "Start a read of the provider's rolling limits on the host's own thread, answering at once"),
    plain!("limits_poll", ReadOnly, crate::host::limits_poll, "What the last limits read has: loading, the usage with its age, or a named failure"),
    plain!("limits_forget", ReadOnly, crate::host::limits_forget, "Drop this process's limits reading for a provider so the next start reads afresh"),
];
