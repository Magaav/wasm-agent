//! Per-component grant policy for the wasm-agent kernel: who may do what, how often, to whom —
//! and a record of every sensitive call.
//!
//! The host asks this crate before it performs a capability call for a component, so a WhatsApp
//! component can post to a real chat only within the limits the operator wrote down. Nothing here
//! touches wasmtime, the filesystem (except the audit sink the host chooses) or the network: it is
//! a pure library and every decision is a function of (policy, state, injected clock).
//!
//! ```
//! use wa_grant_policy::{Engine, Decision, PolicySet, Reason};
//!
//! let policy = PolicySet::parse(r#"{
//!   "version": 1,
//!   "components": {"wa-whatsapp": {"capabilities": {
//!     "whatsapp.send": {"allow": ["chat:self"], "per_target": {"per_minute": 6},
//!                        "rate": {"per_minute": 20}}
//!   }}}
//! }"#).unwrap();
//! let mut engine = Engine::new(policy);
//! let now = 1_760_000_000_000u64;
//! assert_eq!(engine.check("wa-whatsapp", "whatsapp.send", Some("chat:self"), now), Decision::Allow);
//! assert_eq!(
//!     engine.check("wa-whatsapp", "whatsapp.send", Some("chat:other"), now),
//!     Decision::Deny(Reason::TargetNotAllowed)
//! );
//! // no rule, sensitive capability: default deny
//! assert_eq!(
//!     engine.check("wa-whatsapp", "credentials.read", Some("WA_TOKEN"), now),
//!     Decision::Deny(Reason::NoPolicy)
//! );
//! ```
//!
//! Reading order: [`policy`] (the JSON model), [`pattern`], [`bucket`], [`decision`], [`engine`],
//! [`audit`]. The operator-facing schema and the host wiring are in `docs/GRANT-POLICY.md`.
#![forbid(unsafe_code)]

pub mod audit;
pub mod bucket;
pub mod decision;
pub mod engine;
pub mod pattern;
pub mod policy;

pub use audit::{
    AuditError, AuditRecord, AuditSink, DecisionCode, FileAudit, MemoryAudit, TargetMode,
    RECORD_SCHEMA,
};
pub use bucket::{Bucket, DailyCounter, DAY_MS, UNITS_PER_TOKEN};
pub use decision::{Decision, Reason};
pub use engine::{
    audit_target, ApprovalState, Engine, StateError, StateSnapshot, DEFAULT_MAX_TARGET_BUCKETS,
    STATE_SCHEMA,
};
pub use pattern::{Pattern, PatternError, MAX_PATTERN_LEN};
pub use policy::{
    ComponentPolicy, Effect, PolicyError, PolicySet, RateLimit, Rule, TargetRate, DEFAULT_SENSITIVE,
    SCHEMA_VERSION,
};

#[cfg(test)]
mod tests;
