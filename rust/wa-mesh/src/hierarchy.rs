//! `authorize(caller, target, verb)`: may this node command that one?
//!
//! The rule of the fleet is one sentence — *a node may call and control nodes at its own level or
//! below* — and everything else is an operator's explicit grant. Both ends of a call run this same
//! function against the same roster and the same `policy.json`, and the **target's** verdict is the
//! one that executes anything: a caller that lies to itself about its own level reaches a target
//! that will not agree.
//!
//! Order is the grant policy's order, so a reason word means the same kind of thing it means there:
//! revocation first, then denials (never after an allow), then grants, then the hierarchy. A denial
//! is a verdict and never a transport failure: the caller must not fall back to the relay on one, or
//! the old rules would launder a refusal away.
use crate::policy::{Effect, MeshPolicy};
use crate::roster::RosterNode;

/// How much authority a capability needs. Coarse on purpose: a grant is written by a person, and
/// "control" is a thing a person understands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verb {
    Read,
    Call,
    Control,
}

/// Capabilities that only read. Deliberately a list, not a guess: anything not on it is `call` or
/// `control`, which is the answer that needs more authority.
const READ_CAPABILITIES: &[&str] = &[
    "read",
    "read_many",
    "ls",
    "grep",
    "sessions",
    "session",
    "search_messages",
    "recall",
    "status",
    "health",
    "capabilities",
    "list_dir",
];

/// Capabilities that change the target or drive it.
const CONTROL_CAPABILITIES: &[&str] = &[
    "bash",
    "shell",
    "write",
    "edit",
    "client",
    "chat",
    "set_role",
    "set_model",
    "set_provider",
    "subagent",
    "spell_save",
    "spell_run",
    "access",
    "federation",
    "service",
    "operation",
];

impl Verb {
    /// An unknown capability is `Control`: a grant that was written for `read` must not silently
    /// cover a capability nobody classified.
    pub fn from_capability(capability: &str) -> Verb {
        if READ_CAPABILITIES.contains(&capability) {
            Verb::Read
        } else if CONTROL_CAPABILITIES.contains(&capability) {
            Verb::Control
        } else if capability.starts_with("read") || capability.starts_with("grep") || capability.ends_with("_status") {
            Verb::Read
        } else if capability.starts_with("write")
            || capability.starts_with("set_")
            || capability.ends_with("_send")
        {
            Verb::Control
        } else {
            Verb::Call
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Verb::Read => "read",
            Verb::Call => "call",
            Verb::Control => "control",
        }
    }
}

/// The answer, with the word an audit line and an error body use.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Verdict {
    pub allow: bool,
    pub reason: &'static str,
    pub detail: String,
}

impl Verdict {
    fn allow(reason: &'static str, detail: impl Into<String>) -> Verdict {
        Verdict { allow: true, reason, detail: detail.into() }
    }

    fn deny(reason: &'static str, detail: impl Into<String>) -> Verdict {
        Verdict { allow: false, reason, detail: detail.into() }
    }

    pub fn is_allow(&self) -> bool {
        self.allow
    }

    /// `allow` / `deny` for the audit line.
    pub fn decision(&self) -> &'static str {
        if self.allow {
            "allow"
        } else {
            "deny"
        }
    }
}

/// The single place the fleet's rule is written down.
pub fn authorize(
    policy: &MeshPolicy,
    caller: &RosterNode,
    target: &RosterNode,
    verb: Verb,
    now_s: u64,
) -> Verdict {
    if caller.is_revoked(now_s) {
        return Verdict::deny("revoked", format!("caller {} is revoked", caller.name));
    }
    if target.is_revoked(now_s) {
        return Verdict::deny("revoked", format!("target {} is revoked", target.name));
    }
    if caller.node_id == target.node_id {
        return Verdict::deny("self_call", "a node does not mesh-call itself");
    }
    if let Some(grant) = policy.grant_for(&caller.node_id, &target.node_id, verb.as_str()) {
        let note = grant.note.clone().unwrap_or_default();
        return match grant.effect {
            Effect::Deny => Verdict::deny(
                "grant_denied",
                format!("a deny grant matches caller {} to target {} for {}", caller.name, target.name, verb.as_str()),
            ),
            Effect::Allow => Verdict::allow(
                "grant_allowed",
                if note.is_empty() {
                    format!("granted: {} -> {} ({})", caller.name, target.name, verb.as_str())
                } else {
                    format!("granted: {note}")
                },
            ),
        };
    }
    if target.level >= caller.level {
        return Verdict::allow(
            "hierarchy_allowed",
            format!("{} (level {}) may call {} (level {})", caller.name, caller.level, target.name, target.level),
        );
    }
    Verdict::deny(
        "hierarchy_denied",
        format!(
            "{} (level {}) may not call upward to {} (level {}) without a grant",
            caller.name, caller.level, target.name, target.level
        ),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::roster::Draft;
    use crate::testkit::{fleet_key, node};

    fn fleet() -> (MeshPolicy, Vec<RosterNode>) {
        let roster = Draft {
            fleet: "ohana".into(),
            issued_at: 1_762_000_000,
            expires_at: 0,
            nodes: vec![
                node("laptop", 0, &["192.168.1.10:8891"]),
                node("oracle", 1, &[]),
                node("phone", 1, &[]),
                node("guest", 2, &[]),
            ],
        }
        .sign(&fleet_key());
        (MeshPolicy::empty(), roster.nodes)
    }

    fn policy_with(caller: &str, target: &str, verb: &str, effect: &str) -> MeshPolicy {
        MeshPolicy::from_policy_text(&format!(
            r#"{{"version":1,"mesh":{{"version":1,"grants":[
                 {{"caller":"{caller}","target":"{target}","verb":"{verb}","effect":"{effect}"}}]}}}}"#
        ))
        .unwrap()
    }

    #[test]
    fn down_and_across_is_allowed_up_is_not() {
        let (policy, nodes) = fleet();
        let (laptop, oracle, phone, guest) = (&nodes[0], &nodes[1], &nodes[2], &nodes[3]);
        let now = 1_762_000_100;

        let down = authorize(&policy, laptop, oracle, Verb::Control, now);
        assert!(down.is_allow(), "{down:?}");
        assert_eq!(down.reason, "hierarchy_allowed");

        let across = authorize(&policy, oracle, phone, Verb::Control, now);
        assert!(across.is_allow(), "same level must be allowed: {across:?}");

        let up = authorize(&policy, oracle, laptop, Verb::Control, now);
        assert!(!up.is_allow());
        assert_eq!(up.reason, "hierarchy_denied");

        let deeper = authorize(&policy, laptop, guest, Verb::Read, now);
        assert!(deeper.is_allow(), "a superior may call a subordinate: {deeper:?}");

        // A subordinate calling upward is the case a grant exists for: two levels up is still upward.
        let upward = authorize(&policy, guest, oracle, Verb::Read, now);
        assert!(!upward.is_allow());
        assert_eq!(upward.reason, "hierarchy_denied");
    }

    #[test]
    fn the_four_grant_answers_and_the_order_they_arrive_in() {
        let (_, nodes) = fleet();
        let (laptop, oracle) = (&nodes[0], &nodes[1]);
        let now = 1_762_000_100;

        // An upward call with a grant: allowed, and the reason says it was the grant.
        let granted = policy_with(&oracle.node_id, &laptop.node_id, "read", "allow");
        let verdict = authorize(&granted, oracle, laptop, Verb::Read, now);
        assert!(verdict.is_allow());
        assert_eq!(verdict.reason, "grant_allowed");
        // ... but the same grant does not cover `control`.
        assert_eq!(
            authorize(&granted, oracle, laptop, Verb::Control, now).reason,
            "hierarchy_denied"
        );

        // Deny wins over allow for the same pair, and over the hierarchy for a downward call.
        let both = MeshPolicy::from_policy_text(&format!(
            r#"{{"version":1,"mesh":{{"version":1,"grants":[
                 {{"caller":"*","target":"{}","verb":"control","effect":"allow"}},
                 {{"caller":"*","target":"{}","verb":"control","effect":"deny"}}]}}}}"#,
            laptop.node_id, laptop.node_id
        ))
        .unwrap();
        assert_eq!(
            authorize(&both, oracle, laptop, Verb::Control, now).reason,
            "grant_denied"
        );
        assert_eq!(
            authorize(&both, laptop, oracle, Verb::Control, now).reason,
            "hierarchy_allowed",
            "a deny rule scoped to the laptop as target does not touch a call the laptop makes"
        );
    }

    #[test]
    fn revocation_and_self_calls_are_refused_before_any_grant() {
        let (policy, mut nodes) = fleet();
        nodes[3].revoked_at = 1_762_000_050;
        let (laptop, guest) = (&nodes[0], &nodes[3]);
        let verdict = authorize(&policy, guest, laptop, Verb::Read, 1_762_000_100);
        assert_eq!(verdict.reason, "revoked");
        let verdict = authorize(&policy, laptop, guest, Verb::Read, 1_762_000_100);
        assert_eq!(verdict.reason, "revoked");
        let verdict = authorize(&policy, laptop, laptop, Verb::Read, 1_762_000_100);
        assert_eq!(verdict.reason, "self_call");
    }

    #[test]
    fn an_unknown_capability_needs_control_authority() {
        assert_eq!(Verb::from_capability("read"), Verb::Read);
        assert_eq!(Verb::from_capability("grep").as_str(), "read");
        assert_eq!(Verb::from_capability("bash"), Verb::Control);
        assert_eq!(Verb::from_capability("write_file"), Verb::Control);
        assert_eq!(Verb::from_capability("set_model"), Verb::Control);
        assert_eq!(Verb::from_capability("something_new"), Verb::Call);

        // The unknown one is not covered by a read-only grant.
        let (_, nodes) = fleet();
        let (laptop, oracle) = (&nodes[0], &nodes[1]);
        let read_grant = policy_with(&oracle.node_id, &laptop.node_id, "read", "allow");
        let verdict = authorize(&read_grant, oracle, laptop, Verb::from_capability("capability_from_2031"), 1_762_000_100);
        assert!(!verdict.is_allow());
    }
}
