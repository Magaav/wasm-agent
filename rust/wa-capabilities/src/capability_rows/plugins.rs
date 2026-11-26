//! The WASM plugin registry: the list and one invocation, both bound with the interpreter's host
//! pointer. The handlers are in crate::host.
//!
//! One file per area, and this file is the whole registration of its capabilities: build.rs scans
//! this directory (src/registry_scan.rs) and capabilities::registry() is built from what it finds,
//! so adding or moving a capability edits this file and nothing else. docs/HOST.md keeps one
//! documented row per capability, which the drift test in capabilities checks against these rows.

use crate::capabilities::upvalue;

pub const ROWS: &[crate::capabilities::Capability] = &[
    upvalue!("plugins", ReadOnly, crate::host::plugins, "List the registered WASM plugins and their declared parameters"),
    upvalue!("invoke", RunsProcess, crate::host::invoke, "Invoke one registered WASM plugin with JSON arguments"),
];
