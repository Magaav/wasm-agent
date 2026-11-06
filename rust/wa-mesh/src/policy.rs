//! The operator's `"mesh"` section: the fleet key and the per-peer grants.
//!
//! It lives in the same `policy.json` the capability rules live in, because it is the same kind of
//! statement — "what may happen on this node, written down by the person who owns it" — and the
//! merge rules are the capability rules' rules, in the same words:
//!
//! * **deny is evaluated before allow**, so a peer that matches both is refused;
//! * **default deny**: nothing that no rule names is granted (here that is the hierarchy itself: a
//!   call downward needs no grant, anything else needs one that says so);
//! * an **empty pattern is a load error** (write `*` to mean any), patterns are
//!   [`Pattern`](wa_grant_policy::Pattern)s and never regular expressions;
//! * **unknown fields are a load error**, so a typo (`"efect"`, `"targert"`) cannot silently grant.
//!
//! Only the `mesh` section is parsed here. `wa-grant-policy`'s `PolicySet` refuses unknown fields, so
//! a file that carries both sections cannot be handed to it whole yet — that is a one-line change in
//! the grant policy, listed as an open item in `docs/MESH.md` §8, and the reason this reader takes
//! the value apart itself instead of calling `PolicySet::parse` first.
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::path::Path;
use wa_grant_policy::Pattern;

pub const MESH_SCHEMA_VERSION: u32 = 1;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PolicyError(pub String);

impl std::fmt::Display for PolicyError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "invalid mesh policy: {}", self.0)
    }
}

impl std::error::Error for PolicyError {}

fn bad<T>(why: impl Into<String>) -> Result<T, PolicyError> {
    Err(PolicyError(why.into()))
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Effect {
    #[default]
    Allow,
    Deny,
}

/// One per-peer grant. `caller` and `target` match **node ids** and never names: an id is the hash of
/// the key a peer signs with, a name is whatever a peer declared.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Grant {
    pub caller: Pattern,
    pub target: Pattern,
    pub verb: Pattern,
    #[serde(default)]
    pub effect: Effect,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MeshPolicy {
    pub version: u32,
    /// The operator's fleet public key (hex). Empty means no roster can be verified, and a node with
    /// the flag on refuses mesh calls rather than trusting an unverified roster.
    #[serde(default)]
    pub roster_key: String,
    /// Where this node's roster file is, when it is not `<config>/mesh-roster.json`. A relative path
    /// is resolved against the config directory.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub roster: Option<String>,
    #[serde(default)]
    pub grants: Vec<Grant>,
}

impl Default for MeshPolicy {
    fn default() -> Self {
        MeshPolicy {
            version: MESH_SCHEMA_VERSION,
            roster_key: String::new(),
            roster: None,
            grants: Vec::new(),
        }
    }
}

impl MeshPolicy {
    pub fn empty() -> MeshPolicy {
        MeshPolicy::default()
    }

    /// Read the `mesh` section out of a whole `policy.json`. A file with no `mesh` section is not an
    /// error: it is a node with the hierarchy and no grants, which is a valid fleet.
    pub fn from_policy_text(text: &str) -> Result<MeshPolicy, PolicyError> {
        let value: Value = serde_json::from_str(text)
            .map_err(|error| PolicyError(format!("policy.json is not valid JSON: {error}")))?;
        let Some(section) = value.get("mesh") else {
            return Ok(MeshPolicy::empty());
        };
        if section.is_null() {
            return Ok(MeshPolicy::empty());
        }
        let policy: MeshPolicy = serde_json::from_value(section.clone())
            .map_err(|error| PolicyError(format!("mesh section: {error}")))?;
        policy.validate()?;
        Ok(policy)
    }

    pub fn from_policy_file(path: impl AsRef<Path>) -> Result<MeshPolicy, PolicyError> {
        let path = path.as_ref();
        let text = std::fs::read_to_string(path)
            .map_err(|error| PolicyError(format!("{}: {error}", path.display())))?;
        MeshPolicy::from_policy_text(&text)
    }

    pub fn validate(&self) -> Result<(), PolicyError> {
        if self.version != MESH_SCHEMA_VERSION {
            return bad(format!(
                "version {} (this build speaks {MESH_SCHEMA_VERSION})",
                self.version
            ));
        }
        if !self.roster_key.is_empty()
            && (self.roster_key.len() != 64 || self.roster_key.chars().any(|c| !c.is_ascii_hexdigit()))
        {
            return bad("roster_key must be 64 hex characters (an ed25519 public key)");
        }
        for (index, grant) in self.grants.iter().enumerate() {
            for (field, pattern) in [
                ("caller", &grant.caller),
                ("target", &grant.target),
                ("verb", &grant.verb),
            ] {
                if pattern.as_str().is_empty() {
                    return bad(format!("grants[{index}].{field}: empty pattern (use \"*\")"));
                }
            }
            if let Some(note) = &grant.note {
                if note.chars().any(|c| c.is_control()) || note.len() > 240 {
                    return bad(format!("grants[{index}].note must be short text without control characters"));
                }
            }
        }
        Ok(())
    }

    /// The first grant that matches, with `deny` consulted before `allow`. `None` means no rule named
    /// this pair, and the caller falls back to the hierarchy.
    pub fn grant_for(&self, caller_id: &str, target_id: &str, verb: &str) -> Option<&Grant> {
        self.grants
            .iter()
            .filter(|grant| grant.effect == Effect::Deny)
            .find(|grant| matches(grant, caller_id, target_id, verb))
            .or_else(|| {
                self.grants
                    .iter()
                    .filter(|grant| grant.effect == Effect::Allow)
                    .find(|grant| matches(grant, caller_id, target_id, verb))
            })
    }

    pub fn has_grants(&self) -> bool {
        !self.grants.is_empty()
    }
}

fn matches(grant: &Grant, caller_id: &str, target_id: &str, verb: &str) -> bool {
    grant.caller.matches(caller_id) && grant.target.matches(target_id) && grant.verb.matches(verb)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testkit::{fleet_key, node};

    fn ids() -> (String, String) {
        let roster = crate::roster::Draft {
            fleet: "f".into(),
            issued_at: 0,
            expires_at: 0,
            nodes: vec![node("laptop", 0, &[]), node("oracle", 1, &[])],
        }
        .sign(&fleet_key());
        (roster.nodes[0].node_id.clone(), roster.nodes[1].node_id.clone())
    }

    #[test]
    fn a_policy_without_a_mesh_section_is_a_hierarchy_with_no_grants() {
        let policy = MeshPolicy::from_policy_text(
            r#"{"version":1,"components":{"wa-whatsapp":{"capabilities":{}}}}"#,
        )
        .unwrap();
        assert!(!policy.has_grants());
        assert!(policy.roster_key.is_empty());
        assert_eq!(policy.version, MESH_SCHEMA_VERSION);
    }

    #[test]
    fn the_documented_section_parses_and_deny_beats_allow() {
        let (laptop, oracle) = ids();
        let text = format!(
            r#"{{"version":1,"components":{{}},"mesh":{{"version":1,"roster_key":"{}",
                 "grants":[
                   {{"caller":"{oracle}","target":"{laptop}","verb":"read","effect":"allow","note":"read the logs"}},
                   {{"caller":"*","target":"{laptop}","verb":"control","effect":"deny"}},
                   {{"caller":"*","target":"{laptop}","verb":"control","effect":"allow"}}
                 ]}}}}"#,
            "a".repeat(64)
        );
        let policy = MeshPolicy::from_policy_text(&text).unwrap();
        assert_eq!(policy.grants.len(), 3);
        let read = policy.grant_for(&oracle, &laptop, "read").unwrap();
        assert_eq!(read.effect, Effect::Allow);
        assert_eq!(
            policy.grant_for(&oracle, &laptop, "control").unwrap().effect,
            Effect::Deny,
            "a deny rule matching the same pair must win over an allow rule"
        );
        assert!(policy.grant_for(&laptop, &oracle, "control").is_none());
    }

    #[test]
    fn a_typo_is_a_load_error_not_a_silent_grant() {
        // "efect" misspelt: the rule would read as the default (`allow`) if unknown fields were kept.
        let err = MeshPolicy::from_policy_text(
            r#"{"version":1,"mesh":{"version":1,"grants":[{"caller":"*","target":"*","verb":"*","efect":"deny"}]}}"#,
        )
        .unwrap_err();
        assert!(err.0.contains("mesh section"), "{}", err.0);
        assert!(MeshPolicy::from_policy_text(r#"{"version":1,"mesh":{"version":2}}"#).is_err());
        assert!(MeshPolicy::from_policy_text(
            r#"{"version":1,"mesh":{"version":1,"roster_key":"short"}}"#
        )
        .is_err());
        assert!(MeshPolicy::from_policy_text("not json").is_err());
        // An empty pattern is a mistake, never "any".
        assert!(MeshPolicy::from_policy_text(
            r#"{"version":1,"mesh":{"version":1,"grants":[{"caller":"","target":"*","verb":"*"}]}}"#
        )
        .is_err());
    }

    #[test]
    fn patterns_match_ids_the_way_capability_rules_match_targets() {
        let (laptop, oracle) = ids();
        let policy = MeshPolicy::from_policy_text(&format!(
            r#"{{"version":1,"mesh":{{"version":1,"grants":[
                 {{"caller":"{}*","target":"{}","verb":"read*"}}]}}}}"#,
            &oracle[..8],
            laptop
        ))
        .unwrap();
        assert!(policy.grant_for(&oracle, &laptop, "read").is_some());
        assert!(policy.grant_for(&oracle, &laptop, "read_many").is_some());
        assert!(policy.grant_for(&oracle, &laptop, "control").is_none());
        assert!(policy.grant_for(&laptop, &laptop, "read").is_none());
    }
}
