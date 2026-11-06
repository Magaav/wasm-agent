//! The node's rule book and its record: what a capability call is allowed to do, and what it did.
//!
//! - `node_policy`: the effective grant policy, its modes and the audit trail (docs/GRANT-POLICY.md).
//! - `node_telemetry`: the per-component call and health counters (docs/TELEMETRY.md).
//! - `store`: where both of them keep bounded state, and the quota that keeps it bounded (docs/REPLAY.md).
//!
//! Moved out of `wa-host` without rewriting logic. A change here rebuilds this crate, the kernel and
//! the host above it - the point of the split is that it no longer rebuilds the ~13k-line capability
//! crate's ancestors, and that the dependency arrow is explicit rather than implied by one file tree.
// The C ABI is a library API now: a policy and telemetry capability answers a Lua call through a raw `*mut LuaState` the
// interpreter owns for the duration of the call (`pub extern "C-unwind" fn ...(l: *mut LuaState)`). Marking
// those `unsafe fn` would only move the `unsafe` to every registration site without making them safer,
// so the lint is allowed once here, with the reason.
#![allow(clippy::not_unsafe_ptr_arg_deref)]
pub mod node_policy;
pub mod node_telemetry;
pub mod store;
