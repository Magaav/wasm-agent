//! Identity, signing and the network binding: sign and verify, the binding's state and transport,
//! the progress beat /health reads, and the relay that forwards a peer's SSE lines. The handlers
//! are in crate::host.
//!
//! One file per area, and this file is the whole registration of its capabilities: build.rs scans
//! this directory (src/registry_scan.rs) and capabilities::registry() is built from what it finds,
//! so adding or moving a capability edits this file and nothing else. docs/HOST.md keeps one
//! documented row per capability, which the drift test in capabilities checks against these rows.

use crate::capabilities::plain;

pub const ROWS: &[crate::capabilities::Capability] = &[
    plain!("sign", ReadOnly, crate::host::sign, "Sign a message with this node's identity key"),
    plain!("verify", ReadOnly, crate::host::verify, "Verify a signature against a node's public key"),
    plain!("binding_state", ReadOnly, crate::host::binding_state, "This node's binding to its peers and services"),
    plain!("binding_transport", ReadOnly, crate::host::binding_transport, "Transport state for the binding (rendezvous, relay, direct)"),
    plain!("beat", ReadOnly, crate::host::beat, "Report progress on the current run so /health can tell a stuck node from an idle one"),
    plain!("relay", Network, crate::host::relay, "POST to a peer and forward its SSE reply lines to the UI unchanged"),
];
