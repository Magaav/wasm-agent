//! The node's rule book and its record: what a capability call is allowed to do, and what it did.
//!
//! - `node_policy`: the effective grant policy, its modes and the audit trail (docs/GRANT-POLICY.md).
//! - `node_telemetry`: the per-component call and health counters (docs/TELEMETRY.md).
//! - `store`: where both of them keep bounded state, and the quota that keeps it bounded (docs/REPLAY.md).
//!
//! Moved out of `wa-host` without rewriting logic. A change here rebuilds this crate, the kernel and
//! the host above it - the point of the split is that it no longer rebuilds the ~13k-line capability
//! crate's ancestors, and that the dependency arrow is explicit rather than implied by one file tree.
pub mod node_policy;
pub mod node_telemetry;
pub mod store;
