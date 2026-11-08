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
    /// The operator's own statement that this node decides peer calls by the roster.
    ///
    /// `WA_MESH=1` is the process switch; this is the one a *running* node can be given, which is what
    /// `wa fleet push-roster` writes (`rust/wa-mesh/src/fleet.rs`). It only ever takes effect together
    /// with a `roster_key` that verifies a roster: an `enabled` node whose roster does not verify falls
    /// back to today's admission, never to anything weaker.
    ///
    /// **`None` is not `false`.** Since 08/11 the mesh is on by default when a roster verifies against
    /// the pinned key (`docs/MESH.md`, "On by default, off without a roster"), so the section has to be
    /// able to say "the operator wrote nothing here" to let that default apply. `false` is the
    /// operator's own statement and wins over the roster: `features.mesh_component: false` or
    /// `mesh.enabled: false` turns the mesh off on a running node.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub enabled: Option<bool>,
    /// The port this node's mesh listener answers on, when the environment does not name one.
    ///
    /// Enabling the mesh on a live node cannot change a live process's environment, so a node that is
    /// turned on by its own policy needs the rest of the statement there too
    /// (`wa_mesh::host_call::Settings`: environment first, then these, then off). `None` means "no
    /// port was written", never "pick one": a flag alone must not open a port nobody meant to open.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub port: Option<u16>,
    /// The address the listener binds (default `127.0.0.1`; `0.0.0.0` for a LAN-visible fleet).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bind: Option<String>,
    #[serde(default)]
    pub grants: Vec<Grant>,
}

impl Default for MeshPolicy {
    fn default() -> Self {
        MeshPolicy {
            version: MESH_SCHEMA_VERSION,
            roster_key: String::new(),
            roster: None,
            enabled: None,
            port: None,
            bind: None,
            grants: Vec::new(),
        }
    }
}

impl MeshPolicy {
    pub fn empty() -> MeshPolicy {
        MeshPolicy::default()
    }

    /// What the operator's file says about `enabled`, when it says anything at all.
    pub fn enabled_statement(&self) -> Option<bool> {
        self.enabled
    }

    /// Is a fleet key pinned? Without one no roster can verify, so the mesh has nothing to be on by
    /// default (`docs/MESH.md`).
    pub fn has_pinned_key(&self) -> bool {
        !self.roster_key.trim().is_empty()
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

    /// The roster file this policy points at: `mesh.roster`, resolved against the config directory
    /// when it is relative, else `None` and the caller's default applies.
    pub fn roster_path(&self, config: &Path) -> Option<std::path::PathBuf> {
        let configured = self.roster.as_deref()?.trim();
        if configured.is_empty() {
            return None;
        }
        let path = std::path::PathBuf::from(configured);
        Some(if path.is_absolute() { path } else { config.join(path) })
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
        if self.port == Some(0) {
            return bad("port must be 1..=65535 (0 would let the system pick one)");
        }
        if let Some(bind) = &self.bind {
            let bind = bind.trim();
            if bind.is_empty() || bind.len() > 253 {
                return bad("bind must be a host or address, 1..=253 bytes");
            }
            if bind.chars().any(|c| c.is_whitespace() || c.is_control()) {
                return bad("bind must not contain whitespace or control characters");
            }
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

/// The name of the section this crate owns in the node's `policy.json`.
pub const SECTION_NAME: &str = "mesh";

/// The `mesh` section's own validator, for the grant policy's loader (`wa_grant_policy::SectionOwner`).
///
/// This crate is the one that knows the section's schema, so it is the one that says whether a section
/// is usable. The grant policy calls it while loading a `policy.json`, which is how an invalid `mesh`
/// section becomes a named error in `host.policy_status` **without** taking the capability rules beside
/// it down (the 08/11 incident: a valid mesh section used to make every component rule unreadable).
/// `null` means "no section", which is a valid empty statement.
pub fn validate_section(value: &serde_json::Value) -> Result<(), String> {
    if value.is_null() {
        return Ok(());
    }
    let policy: MeshPolicy = serde_json::from_value(value.clone())
        .map_err(|error| format!("mesh section: {error}"))?;
    policy.validate().map_err(|error| error.0)
}

/// This crate's registration for the grant policy's section registry.
pub fn section_owner() -> wa_grant_policy::SectionOwner {
    wa_grant_policy::SectionOwner { name: SECTION_NAME, validate: validate_section }
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
        // Absent means "the operator wrote nothing here": not off, and not on either - the gate's
        // default decides (on when a roster verifies against a pinned key).
        assert_eq!(policy.enabled, None);
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

    #[test]
    fn the_operator_can_enable_the_roster_in_the_policy_a_running_node_reads() {
        let policy = MeshPolicy::from_policy_text(&format!(
            r#"{{"version":1,"mesh":{{"version":1,"enabled":true,"roster_key":"{}","roster":"mesh-roster.json"}}}}"#,
            "a".repeat(64)
        ))
        .unwrap();
        assert_eq!(policy.enabled, Some(true));
        assert!(policy.has_pinned_key());
        assert_eq!(
            policy.roster_path(Path::new("/home/x/.wasm-agent")).unwrap(),
            std::path::PathBuf::from("/home/x/.wasm-agent/mesh-roster.json")
        );
        // A typo in `enabled` is a load error, not a silent off.
        assert!(MeshPolicy::from_policy_text(
            r#"{"version":1,"mesh":{"version":1,"enabled":"yes"}}"#
        )
        .is_err());
    }

    /// The section owner: what the grant policy calls while it loads a `policy.json`. A valid section is
    /// accepted; an invalid one is refused by name (and the grant policy reports it rather than dropping
    /// the rules); `null` is an empty statement.
    #[test]
    fn the_section_owner_accepts_a_valid_section_and_names_what_is_wrong() {
        let owner = section_owner();
        assert_eq!(owner.name, SECTION_NAME);
        let valid = serde_json::json!({"version": 1, "enabled": true, "roster_key": "a".repeat(64)});
        assert_eq!((owner.validate)(&valid), Ok(()));
        assert_eq!((owner.validate)(&serde_json::Value::Null), Ok(()));
        assert_eq!((owner.validate)(&serde_json::json!({"version": 1, "enabled": false})), Ok(()));
        let wrong_version = (owner.validate)(&serde_json::json!({"version": 9})).unwrap_err();
        assert!(wrong_version.contains("version 9"), "{wrong_version}");
        let typo = (owner.validate)(&serde_json::json!({"version": 1, "grants": [{"caller": "*", "target": "*", "verb": "*", "efect": "deny"}]})).unwrap_err();
        assert!(typo.contains("mesh section"), "{typo}");
        assert!((owner.validate)(&serde_json::json!({"version": 1, "roster_key": "short"})).is_err());
    }

    /// The whole point of the owner: a file with a valid `mesh` section and capability rules is a file
    /// the grant policy parses with the rules intact (the 08/11 incident is `wa-grant-policy`'s test;
    /// this one proves the section the *mesh* wrote passes *its own* validator).
    #[test]
    fn a_policy_file_with_a_mesh_section_validates_with_the_grant_policy() {
        let text = format!(
            r#"{{"version":1,"mesh":{{"version":1,"enabled":true,"roster_key":"{}","roster":"mesh-roster.json"}},
                 "components":{{"wa-whatsapp":{{"capabilities":{{"net.dial":{{"allow":["*.whatsapp.net:443"]}}}}}}}}}}"#,
            "a".repeat(64)
        );
        let set = wa_grant_policy::PolicySet::parse_owned(&text, &[section_owner()])
            .expect("the file parses with its mesh section");
        assert!(!set.has_section_errors(), "{:?}", set.section_errors);
        assert!(set.rule("wa-whatsapp", "net.dial").is_some(), "the component rules are readable");
        // ...and a broken section is named, with the rules still there.
        let broken = text.replace(r#""version":1,"enabled":true"#, r#""version":1,"enabled":true,"port":0"#);
        let set = wa_grant_policy::PolicySet::parse_owned(&broken, &[section_owner()]).expect("parses");
        assert!(set.section_error("mesh").unwrap_or_default().contains("port"), "{:?}", set.section_errors);
        assert!(set.rule("wa-whatsapp", "net.dial").is_some(), "the component rules are still readable");
    }
}
