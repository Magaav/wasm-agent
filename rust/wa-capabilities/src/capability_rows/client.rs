//! The user's machine through the outbound client bridge. Both rows are bound with the interpreter's
//! host pointer. The handlers are in crate::host.
//!
//! One file per area, and this file is the whole registration of its capabilities: build.rs scans
//! this directory (src/registry_scan.rs) and capabilities::registry() is built from what it finds,
//! so adding or moving a capability edits this file and nothing else. docs/HOST.md keeps one
//! documented row per capability, which the drift test in capabilities checks against these rows.

use crate::capabilities::upvalue;

pub const ROWS: &[crate::capabilities::Capability] = &[
    upvalue!("client", Device, crate::host::client, "Act on the user's machine through the outbound client bridge: screenshot, input, shell, browser/CDP"),
    upvalue!("client_status", ReadOnly, crate::host::client_status, "Whether the desktop client is connected, and what it is doing"),
];
