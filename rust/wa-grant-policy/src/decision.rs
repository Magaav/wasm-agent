//! What a policy check answers, and why.
use crate::audit::DecisionCode;
use serde::{Deserialize, Serialize};
use std::fmt;

/// Why a call was refused, half-refused or held.
///
/// The names are the stable wire form (snake_case in audit records); the host maps them to guest
/// errors and operator text. `Allow` has no reason.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Reason {
    /// The component has no rule for a capability that is sensitive by default (or by the file):
    /// default deny.
    NoPolicy,
    /// The rule's `effect` is `deny`.
    PolicyDenied,
    /// A `deny` pattern matched the target. Deny wins over allow.
    TargetDenied,
    /// The rule lists allowed targets and this one is not among them (or the call had no target
    /// while the rule requires one).
    TargetNotAllowed,
    /// `require_approval` is set and no unused, unexpired approval covers this call.
    ApprovalRequired,
    /// The capability-wide bucket is empty.
    CapabilityRateLimited,
    /// The per-target bucket is empty.
    TargetRateLimited,
    /// The capability's `daily_cap` is reached for this UTC day.
    DailyCapReached,
    /// The decision could not be audited and the engine refuses unauditable sensitive calls.
    AuditUnavailable,
}

impl Reason {
    pub fn as_str(&self) -> &'static str {
        match self {
            Reason::NoPolicy => "no_policy",
            Reason::PolicyDenied => "policy_denied",
            Reason::TargetDenied => "target_denied",
            Reason::TargetNotAllowed => "target_not_allowed",
            Reason::ApprovalRequired => "approval_required",
            Reason::CapabilityRateLimited => "capability_rate_limited",
            Reason::TargetRateLimited => "target_rate_limited",
            Reason::DailyCapReached => "daily_cap_reached",
            Reason::AuditUnavailable => "audit_unavailable",
        }
    }
}

impl fmt::Display for Reason {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// The answer to one policy check.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Decision {
    /// Go ahead; any budget this call needed has been charged.
    Allow,
    /// Refused. The host returns a `refused(reason)` error to the component and never performs the
    /// capability call.
    Deny(Reason),
    /// Refused for now; `retry_after_ms` is the exact wait before a retry can succeed (the host may
    /// surface it as `again` plus a delay, or as a refusal with a number).
    RateLimited { retry_after_ms: u64, reason: Reason },
    /// Held for a person: the host asks the operator, records an approval
    /// ([`Engine::approve`](crate::Engine::approve)) and calls again.
    NeedsApproval(Reason),
}

impl Decision {
    /// Is the call allowed? Only `Allow` is.
    pub fn is_allow(&self) -> bool {
        matches!(self, Decision::Allow)
    }

    /// The audit record's decision word.
    pub fn code(&self) -> DecisionCode {
        match self {
            Decision::Allow => DecisionCode::Allow,
            Decision::Deny(_) => DecisionCode::Deny,
            Decision::RateLimited { .. } => DecisionCode::RateLimited,
            Decision::NeedsApproval(_) => DecisionCode::NeedsApproval,
        }
    }

    /// The stable reason word (`allowed` when there is none).
    pub fn reason_str(&self) -> &'static str {
        match self {
            Decision::Allow => "allowed",
            Decision::Deny(r) | Decision::NeedsApproval(r) => r.as_str(),
            Decision::RateLimited { reason, .. } => reason.as_str(),
        }
    }

    /// Milliseconds until a retry could succeed, when the decision has an opinion.
    pub fn retry_after_ms(&self) -> Option<u64> {
        match self {
            Decision::RateLimited { retry_after_ms, .. } => Some(*retry_after_ms),
            _ => None,
        }
    }
}

impl fmt::Display for Decision {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Decision::Allow => f.write_str("allow"),
            Decision::Deny(r) => write!(f, "deny({r})"),
            Decision::RateLimited { retry_after_ms, reason } => {
                write!(f, "rate_limited({reason}, retry_after_ms={retry_after_ms})")
            }
            Decision::NeedsApproval(r) => write!(f, "needs_approval({r})"),
        }
    }
}
