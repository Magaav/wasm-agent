//! HTTP: one bounded request, and the two streaming forms that hand body chunks or server-sent event
//! lines to Lua. The handlers are in crate::host.
//!
//! One file per area, and this file is the whole registration of its capabilities: build.rs scans
//! this directory (src/registry_scan.rs) and capabilities::registry() is built from what it finds,
//! so adding or moving a capability edits this file and nothing else. docs/HOST.md keeps one
//! documented row per capability, which the drift test in capabilities checks against these rows.

use crate::capabilities::plain;

pub const ROWS: &[crate::capabilities::Capability] = &[
    plain!("http", Network, crate::host::http, "One bounded HTTP request; returns status, headers and body"),
    plain!("http_stream", Network, crate::host::http_stream, "A streaming HTTP request, delivering body chunks to Lua"),
    plain!("http_sse", Network, crate::host::http_sse, "A streaming HTTP request that hands over server-sent event lines"),
];
