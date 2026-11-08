//! The policy model: JSON in, validated rules out.
//!
//! Schema (version 1), all field names snake_case, unknown fields *inside a rule* are a **load error**
//! so a typo (`per_minutes`, `require_aprovall`) can never silently drop a limit:
//!
//! ```json
//! {
//!   "version": 1,
//!   "sensitive_capabilities": ["kv.write"],
//!   "components": {
//!     "wa-whatsapp": {
//!       "capabilities": {
//!         "whatsapp.send": {
//!           "effect": "allow",
//!           "sensitive": true,
//!           "require_approval": false,
//!           "allow": ["self"],
//!           "deny": ["*@broadcast"],
//!           "rate": { "per_minute": 20, "burst": 20 },
//!           "per_target": { "per_minute": 6 },
//!           "target_rates": [
//!             { "pattern": "chat:alerts", "per_minute": 1, "exempt_from_global": true }
//!           ],
//!           "daily_cap": 500
//!         }
//!       }
//!     }
//!   }
//! }
//! ```
//!
//! Meaning of each rule field:
//!
//! * `effect` — `"allow"` (default) or `"deny"`: `"deny"` refuses every call to the capability
//!   before any target or rate is looked at.
//! * `allow` — target patterns. Empty list = any target (list targets for anything sensitive).
//! * `deny` — target patterns that win over `allow`; deny is evaluated first.
//! * `sensitive` — overrides the default-sensitive list for this capability. A sensitive
//!   capability is audited on every call, and **denied** when the component has no rule for it.
//! * `require_approval` — the call returns [`Decision::NeedsApproval`](crate::Decision) until the
//!   host records an approval ([`Engine::approve`](crate::Engine::approve)).
//! * `rate` — capability-wide token bucket, tokens per minute, optional `burst` (default: one
//!   minute's worth).
//! * `per_target` — one token bucket per distinct target (a chat, an authority, a key).
//! * `target_rates` — per-pattern override of `per_target`, first match wins. `exempt_from_global`
//!   means a matching target does not consume the capability-wide bucket.
//! * `daily_cap` — hard count per capability per UTC day (injected clock, ms since the epoch).
//!
//! ## Sections this crate does not read
//!
//! One `policy.json` carries more than capability rules: `features` (docs/FEATURES.md), `mesh`
//! (docs/MESH.md), `vault` (docs/VAULT.md), `models` (docs/MODEL-GATEWAY.md), and whatever the next one
//! is called. Before 08/11 every one of them was an unknown field here, and an unknown field was a load
//! error — so a node whose operator hand-wrote a `mesh` section was `Mode::Policy` with an *empty*
//! policy, i.e. every component's own rules answered `deny(no_policy)` (the live incident of 08/11
//! 03:51–04:10 on openclaw: `wa-whatsapp` `net.dial` refused though its rule was right there in the
//! file).
//!
//! So the top level is parsed in two stages, and the strictness rule follows the blast radius:
//!
//! * a **known section** is validated field by field, exactly as before: a typo in a rule is a load
//!   error;
//! * a **section this crate does not interpret** is *carried* ([`PolicySet::sections`], opaque JSON) and
//!   never changes a rule. A future section can therefore reach a node's file before the binary that
//!   reads it, which is the whole point of a section;
//! * a section with an **owner** in this process (the crate that knows its schema, registered through
//!   [`SectionOwner`]) is validated by that owner, and a section that is invalid — or that is not even a
//!   JSON object — is recorded in [`PolicySet::section_errors`], reported by `host.policy_status` and
//!   logged once. It is **never** silently ignored and **never** takes the rules down with it: a broken
//!   `mesh` section must not be able to refuse a `wa-whatsapp` send.
use crate::pattern::{Pattern, PatternError};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fmt;
use std::path::Path;

/// Capabilities that are sensitive even when the policy file says nothing about them.
///
/// A sensitive capability is audited on every call and denied when there is no rule for it. The
/// list is deliberately short and about *effects outside the component's own sandbox*: a secret
/// read, an outbound connection, a message that a person will see, a process, a shadow copy of
/// state inside the component's durable namespace.
///
/// The `wasi.*` names are the interface decisions of the WASI 0.3 runner (`docs/WASI-INTERFACES.md`,
/// tier B): one is asked per granted scope element at start (`wasi.filesystem` per preopen,
/// `wasi.env` per variable name, `wasi.sockets` per granted address), and the call-time checks keep
/// the capability names the `wa:kernel` path already uses (`net.dial`, `net.bind`, `kv.read`,
/// `kv.write`, `config.read`). They are sensitive for the same reason as the rest of the list: each
/// one is a decision about reaching outside the component, and an operator who upgrades a node to a
/// `policy.json` should have to say yes to them rather than inherit them.
pub const DEFAULT_SENSITIVE: &[&str] = &[
    "credentials.read",
    "net.dial",
    "net.bind",
    "http.request",
    "whatsapp.send",
    "exec.run",
    "kv.write",
    "wasi.filesystem",
    "wasi.env",
    "wasi.stdin",
    "wasi.sockets",
    "wasi.keyvalue",
    "wasi.config",
    "wasi.import",
];

/// Only one schema version exists; a different number is refused, never guessed at.
pub const SCHEMA_VERSION: u32 = 1;

/// Why a policy file was refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PolicyError(pub String);

impl fmt::Display for PolicyError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "invalid grant policy: {}", self.0)
    }
}

impl std::error::Error for PolicyError {}

impl From<PatternError> for PolicyError {
    fn from(e: PatternError) -> Self {
        PolicyError(e.0)
    }
}

fn bad<T>(why: impl Into<String>) -> Result<T, PolicyError> {
    Err(PolicyError(why.into()))
}

/// A whole policy file.
///
/// `components` (the rules), `version` and `sensitive_capabilities` are this crate's; `features` and
/// every other top-level member is carried for the crate that owns it (`sections`). The top level is
/// deliberately *not* `deny_unknown_fields`: a section this crate does not know must never be able to
/// make the rules unreadable (see the module docs). Everything *inside* a rule still is.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicySet {
    pub version: u32,
    /// Capabilities this node treats as sensitive in addition to [`DEFAULT_SENSITIVE`].
    #[serde(default)]
    pub sensitive_capabilities: Vec<String>,
    /// The node's feature switches (`docs/FEATURES.md`). This engine does not read them: the switches
    /// live in the same file as the rules so an operator has one place for "what this node may do"
    /// and "what this node routes", and the crate that resolves them (`wa-features`) is the only
    /// reader. They are kept as JSON here so this crate does not have to know which features exist,
    /// and so a node whose binary is older than its policy file still parses that file.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub features: Option<serde_json::Value>,
    #[serde(default)]
    pub components: BTreeMap<String, ComponentPolicy>,
    /// Every other top-level section, verbatim: `mesh`, `vault`, `models`, and any section a later crate
    /// owns. Carried so a file that names one parses; never interpreted here, so it cannot change a
    /// rule. [`PolicySet::section`] is the reader's door.
    #[serde(default, flatten)]
    pub sections: BTreeMap<String, serde_json::Value>,
    /// Sections that are there and are not usable: `not_an_object`, or whatever the section's owner
    /// refused. Reported by `host.policy_status` and logged once by the loader; **never** a reason to
    /// drop the rules beside them.
    #[serde(skip)]
    pub section_errors: BTreeMap<String, String>,
}

/// The crate that knows one top-level section's schema (`mesh` → `wa-mesh-core`, and so on).
///
/// `validate` gets the section's JSON as written and answers why it is unusable, if it is: version,
/// required fields, a key that is not the right length — the checks the reader itself would make. The
/// grant policy calls it while loading, so an invalid section is named on the node's log and in
/// `host.policy_status` instead of being discovered (or not) by whoever reads that section next.
pub struct SectionOwner {
    pub name: &'static str,
    pub validate: fn(&serde_json::Value) -> Result<(), String>,
}

/// One component's rules, keyed by capability (`whatsapp.send`, `net.dial`, …).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ComponentPolicy {
    /// Free text for the operator; never read by the engine.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    #[serde(default)]
    pub capabilities: BTreeMap<String, Rule>,
}

/// What a rule says about one capability.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Rule {
    #[serde(default)]
    pub effect: Effect,
    #[serde(default)]
    pub allow: Vec<Pattern>,
    #[serde(default)]
    pub deny: Vec<Pattern>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sensitive: Option<bool>,
    #[serde(default)]
    pub require_approval: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rate: Option<RateLimit>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub per_target: Option<RateLimit>,
    #[serde(default)]
    pub target_rates: Vec<TargetRate>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub daily_cap: Option<u32>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Effect {
    #[default]
    Allow,
    Deny,
}

/// A token bucket, expressed in the unit the operator thinks in: tokens per minute.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RateLimit {
    pub per_minute: u32,
    /// Bucket size in tokens; default is one minute's worth, i.e. no extra slack.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub burst: Option<u32>,
}

impl RateLimit {
    pub fn new(per_minute: u32, burst: Option<u32>) -> RateLimit {
        RateLimit { per_minute, burst }
    }

    /// Bucket capacity in tokens.
    pub fn capacity(&self) -> u64 {
        u64::from(self.burst.unwrap_or(self.per_minute))
    }

    fn check(&self, where_: &str) -> Result<(), PolicyError> {
        if self.per_minute == 0 {
            return bad(format!("{where_}.per_minute must be greater than 0"));
        }
        if self.burst == Some(0) {
            return bad(format!("{where_}.burst must be greater than 0"));
        }
        Ok(())
    }
}

/// A per-target rate override; the first pattern that matches a target wins. The limit is written
/// inline (`per_minute` / `burst`) so the JSON stays flat and unknown fields stay a load error.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TargetRate {
    pub pattern: Pattern,
    pub per_minute: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub burst: Option<u32>,
    /// A matching target does not consume the capability-wide bucket (e.g. an alerts chat).
    #[serde(default)]
    pub exempt_from_global: bool,
}

impl TargetRate {
    /// The bucket this override installs for a matching target.
    pub fn limit(&self) -> RateLimit {
        RateLimit { per_minute: self.per_minute, burst: self.burst }
    }
}

impl PolicySet {
    /// Load and validate from JSON text.
    pub fn parse(text: &str) -> Result<PolicySet, PolicyError> {
        PolicySet::parse_owned(text, &[])
    }

    /// [`PolicySet::parse`], with the section owners this process has: each owner validates its own
    /// section, and a section that does not validate lands in [`PolicySet::section_errors`] (reported)
    /// while the rules beside it keep working. No owner, no opinion: the section is carried verbatim.
    pub fn parse_owned(text: &str, owners: &[SectionOwner]) -> Result<PolicySet, PolicyError> {
        let mut set: PolicySet = serde_json::from_str(text)
            .map_err(|e| PolicyError(format!("not valid JSON for schema {SCHEMA_VERSION}: {e}")))?;
        set.check_sections(owners);
        set.validate()?;
        Ok(set)
    }

    /// Load and validate from a file (`docs/GRANT-POLICY.md` describes the shape).
    pub fn from_file(path: impl AsRef<Path>) -> Result<PolicySet, PolicyError> {
        let path = path.as_ref();
        let text = std::fs::read_to_string(path)
            .map_err(|e| PolicyError(format!("{}: {e}", path.display())))?;
        PolicySet::parse(&text)
    }

    /// An empty policy: every capability that is sensitive by default is denied, nothing else.
    pub fn empty() -> PolicySet {
        PolicySet {
            version: SCHEMA_VERSION,
            sensitive_capabilities: Vec::new(),
            features: None,
            components: BTreeMap::new(),
            sections: BTreeMap::new(),
            section_errors: BTreeMap::new(),
        }
    }

    /// The JSON of a top-level section this crate carries but does not interpret (`mesh`, `vault`, …),
    /// or `None` when the file has no such section.
    pub fn section(&self, name: &str) -> Option<&serde_json::Value> {
        self.sections.get(name).filter(|value| !value.is_null())
    }

    /// Why a section is unusable, when one is (`[not_an_object]`, or the owner's own words).
    pub fn section_error(&self, name: &str) -> Option<&str> {
        self.section_errors.get(name).map(String::as_str)
    }

    /// Is a section there and *not* usable? A loader reports every one of these by name.
    pub fn has_section_errors(&self) -> bool {
        !self.section_errors.is_empty()
    }

    /// The sections this file carries that no owner in this process interprets - a notice, not an
    /// error: a section a newer binary owns is expected to be one of these.
    pub fn unclaimed_sections(&self, owners: &[SectionOwner]) -> Vec<&str> {
        self.sections
            .keys()
            .map(String::as_str)
            .filter(|name| !owners.iter().any(|owner| owner.name == *name))
            .collect()
    }

    /// The section half of validation: every carried section must be a JSON object (or `null`, which
    /// means "nothing here"), and an owner's `validate` must accept it. Problems are *recorded*, never
    /// returned: dropping the rules because a sibling section is malformed is the 08/11 incident.
    fn check_sections(&mut self, owners: &[SectionOwner]) {
        let mut errors = BTreeMap::new();
        for (name, value) in &self.sections {
            if let Err(why) = check_name("sections key", name) {
                errors.insert(name.clone(), why.0);
                continue;
            }
            if value.is_null() {
                continue;
            }
            if !value.is_object() {
                errors.insert(name.clone(), "not_an_object".to_string());
                continue;
            }
            for owner in owners.iter().filter(|owner| owner.name == name.as_str()) {
                if let Err(why) = (owner.validate)(value) {
                    errors.insert(name.clone(), why);
                }
            }
        }
        self.section_errors = errors;
    }

    /// Check everything the engine relies on: version, names, rate bounds, no empty rules that
    /// would read as "allow anything".
    pub fn validate(&self) -> Result<(), PolicyError> {
        if self.version != SCHEMA_VERSION {
            return bad(format!("version {} (this build speaks {SCHEMA_VERSION})", self.version));
        }
        for extra in &self.sensitive_capabilities {
            check_name("sensitive_capabilities[]", extra)?;
        }
        for (component, cp) in &self.components {
            check_name("components key", component)?;
            for (capability, rule) in &cp.capabilities {
                let at = format!("components.{component}.capabilities.{capability}");
                check_name(&at, capability)?;
                if rule.effect == Effect::Deny && (!rule.allow.is_empty() || !rule.deny.is_empty()) {
                    return bad(format!("{at}: effect \"deny\" already refuses everything; drop allow/deny"));
                }
                if let Some(rate) = &rule.rate {
                    rate.check(&format!("{at}.rate"))?;
                }
                if let Some(rate) = &rule.per_target {
                    rate.check(&format!("{at}.per_target"))?;
                }
                for (i, tr) in rule.target_rates.iter().enumerate() {
                    tr.limit().check(&format!("{at}.target_rates[{i}]"))?;
                }
                if rule.daily_cap == Some(0) {
                    return bad(format!("{at}.daily_cap must be greater than 0"));
                }
            }
        }
        Ok(())
    }

    /// The rule for a capability, if the policy file has one.
    pub fn rule(&self, component: &str, capability: &str) -> Option<&Rule> {
        self.components.get(component)?.capabilities.get(capability)
    }

    /// Is this capability sensitive? Explicit rule flag first, then the built-in list plus this
    /// file's `sensitive_capabilities`.
    pub fn is_sensitive(&self, component: &str, capability: &str) -> bool {
        if let Some(flag) = self.rule(component, capability).and_then(|r| r.sensitive) {
            return flag;
        }
        DEFAULT_SENSITIVE.contains(&capability)
            || self.sensitive_capabilities.iter().any(|c| c == capability)
    }

    /// Every sensitive capability is audited; so is any refusal (a denial is evidence even for a
    /// capability the file does not flag).
    pub fn is_audited(&self, component: &str, capability: &str) -> bool {
        self.is_sensitive(component, capability)
    }
}

fn check_name(where_: &str, name: &str) -> Result<(), PolicyError> {
    if name.is_empty() {
        return bad(format!("{where_} must not be empty"));
    }
    if name.chars().any(|c| c.is_control()) {
        return bad(format!("{where_} must not contain control characters"));
    }
    if name.len() > 128 {
        return bad(format!("{where_} longer than 128 bytes"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_the_documented_shape() {
        let set = PolicySet::parse(
            r#"{"version":1,"components":{"wa-whatsapp":{"capabilities":{
                 "whatsapp.send":{"allow":["self"],"deny":["*@broadcast"],
                                  "rate":{"per_minute":20},"per_target":{"per_minute":6},
                                  "target_rates":[{"pattern":"chat:alerts","per_minute":1,
                                                   "exempt_from_global":true}],
                                  "daily_cap":500}}}}}"#,
        )
        .unwrap();
        let rule = set.rule("wa-whatsapp", "whatsapp.send").unwrap();
        assert_eq!(rule.rate.unwrap().capacity(), 20);
        assert_eq!(rule.per_target.unwrap().capacity(), 6);
        assert!(rule.target_rates[0].exempt_from_global);
        assert_eq!(rule.daily_cap, Some(500));
        assert!(rule.allow[0].matches("self"));
        assert!(rule.deny[0].matches("1-2@broadcast"));
    }

    /// The `features` section (docs/FEATURES.md) rides in the same file as the rules, and this engine
    /// deliberately does not read it: what a node *may* do and what it *routes to* live in one file so an
    /// operator has one place, and `wa-features` is the only reader of the section.
    ///
    /// The field exists for one reason. `deny_unknown_fields` is this crate's contract (a misspelled
    /// `per_minutes` must not read as "no limit"), so before the field a policy file with a `features`
    /// section failed to load - and a policy file that fails to load is `Mode::Policy` with an empty
    /// policy, i.e. every sensitive capability refused with `no_policy`. A feature switch must never be
    /// able to do that.
    #[test]
    fn a_features_section_is_carried_and_does_not_change_a_rule() {
        let with = PolicySet::parse(
            r#"{"version":1,"sensitive_capabilities":[],"features":{"memory":true,"hooks":false},
                "components":{"wa-whatsapp":{"capabilities":{"kv.write":{"allow":["ix/*"]}}}}}"#,
        )
        .expect("a policy file with a features section parses");
        assert_eq!(
            with.features.as_ref().and_then(|features| features.get("memory")),
            Some(&serde_json::Value::Bool(true))
        );
        let without = PolicySet::parse(
            r#"{"version":1,"sensitive_capabilities":[],"components":{"wa-whatsapp":{"capabilities":{"kv.write":{"allow":["ix/*"]}}}}}"#,
        )
        .expect("the same file without the section parses");
        assert_eq!(with.components, without.components, "the features section decides no rule");
        assert_eq!(without.features, None);
        // ...and a misspelled *rule* member is still refused, mesh or no mesh: the field did not open
        // the schema this crate owns.
        assert!(PolicySet::parse(
            r#"{"version":1,"components":{"c":{"capabilities":{"x":{"rate":{"per_minutes":5}}}}},"mesh":{"version":1}}"#
        )
        .is_err());
    }

    /// The incident of 08/11 03:51–04:10 (openclaw), reproduced exactly: a `mesh` section hand-added to
    /// the node's `policy.json` ({version, enabled, roster_key, roster}) and the component's own rules
    /// answered `deny(no_policy)` - `wa-whatsapp` `net.dial` refused with its rule right there in the
    /// file. The fix: a section this crate does not interpret is carried, so the rules load and are
    /// enforced, whatever the section says.
    #[test]
    fn the_0811_incident_a_mesh_section_does_not_make_the_component_rules_unreadable() {
        let key = "a".repeat(64);
        for enabled in [true, false] {
            let text = serde_json::json!({
                "version": 1,
                "sensitive_capabilities": [],
                "mesh": {"version": 1, "enabled": enabled, "roster_key": key, "roster": "mesh-roster.json"},
                "components": {"wa-whatsapp": {"capabilities": {"net.dial": {
                    "allow": ["*.whatsapp.net:443"],
                    "rate": {"per_minute": 60, "burst": 120}
                }}}}
            })
            .to_string();
            let set = PolicySet::parse(&text).expect("a file with a mesh section parses");
            assert!(!set.has_section_errors(), "a valid mesh section is not an error: {:?}", set.section_errors);
            assert!(set.section("mesh").is_some(), "the section is carried for its owner to read");
            assert_eq!(set.components.len(), 1, "the rules are there");
            let rule = set.rule("wa-whatsapp", "net.dial").expect("the net.dial rule is readable");
            assert!(rule.allow[0].matches("mmg.whatsapp.net:443"));
            assert_eq!(rule.rate.unwrap().capacity(), 120);
            // And the answer the operator saw as `deny(no_policy)` is an allow again.
            let mut engine = crate::Engine::new(set);
            assert_eq!(
                engine.check("wa-whatsapp", "net.dial", Some("mmg.whatsapp.net:443"), 1_760_000_000_000),
                crate::Decision::Allow
            );
        }
    }

    /// A section that is there and unusable is *reported*, and the rules beside it still load: the
    /// failure mode is loud, never a silent drop. (The real `mesh` owner is `wa-mesh-core`; a fake owner
    /// here proves the registry half without a dependency.)
    #[test]
    fn an_invalid_section_is_recorded_and_never_drops_the_rules() {
        let rules = r#""components":{"wa-whatsapp":{"capabilities":{"kv.write":{"allow":["ix/*"]}}}},"#;
        let set = PolicySet::parse(&format!(r#"{{"version":1,{rules}"mesh":"on"}}"#)).expect("parses");
        assert_eq!(set.section_error("mesh"), Some("not_an_object"));
        assert!(set.rule("wa-whatsapp", "kv.write").is_some(), "the rules survived");

        fn refuse_version(value: &serde_json::Value) -> Result<(), String> {
            match value.get("version").and_then(|v| v.as_u64()) {
                Some(1) => Ok(()),
                Some(other) => Err(format!("version {other} (this build speaks 1)")),
                None => Err("version: missing".into()),
            }
        }
        let owners = [SectionOwner { name: "mesh", validate: refuse_version }];
        let set = PolicySet::parse_owned(&format!(r#"{{"version":1,{rules}"mesh":{{"version":9}}}}"#), &owners)
            .expect("an invalid section is reported, not fatal");
        assert_eq!(set.section_error("mesh"), Some("version 9 (this build speaks 1)"));
        assert!(set.rule("wa-whatsapp", "kv.write").is_some(), "the rules survived");
        assert_eq!(set.unclaimed_sections(&owners), Vec::<&str>::new());

        let set = PolicySet::parse_owned(&format!(r#"{{"version":1,{rules}"mesh":{{"version":1}}}}"#), &owners)
            .expect("parses");
        assert!(!set.has_section_errors(), "a valid section is clean");
    }

    /// The file a deploy installs (`policies/default.json`) carries the section, so it must parse
    /// through this engine: a shipped default that its own engine refuses would be a node with no rules.
    #[test]
    fn the_shipped_default_policy_parses_with_its_features_section() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../policies/default.json");
        let text = std::fs::read_to_string(path).expect("policies/default.json is readable");
        let set = PolicySet::parse(&text).expect("the shipped default parses");
        assert!(set.features.is_some(), "the shipped default names the feature switches");
    }

    #[test]
    fn unknown_fields_and_wrong_versions_are_refused() {
        // "per_minutes" is the typo this test exists for: a misspelt limit inside a rule is a load
        // error, because guessing it away would widen what the file allows.
        assert!(PolicySet::parse(r#"{"version":1,"components":{"c":{"capabilities":{"x":{"rate":{"per_minutes":5}}}}}}"#).is_err());
        assert!(PolicySet::parse(r#"{"version":2,"components":{}}"#).is_err());
        assert!(PolicySet::parse(r#"{"version":1,"components":{"c":{"capabilites":{}}}}"#).is_err());
        assert!(PolicySet::parse("{}").is_err());
        assert!(PolicySet::parse("not json").is_err());
    }

    /// The top level is deliberately *not* `deny_unknown_fields` any more (module docs, "Sections this
    /// crate does not read"): a member this crate does not interpret is carried, so a top-level typo is a
    /// carried section rather than a load error - reportable by `host.policy_status`
    /// (`unclaimed_sections` + the loader's log line), never guessed at. What it must never do is change
    /// a rule.
    #[test]
    fn a_member_this_crate_does_not_interpret_is_carried_and_changes_no_rule() {
        let with = PolicySet::parse(
            r#"{"version":1,"default":"allow","components":{"c":{"capabilities":{"kv.write":{"allow":["ix/*"]}}}}}"#,
        )
        .expect("an unknown top-level member is carried, not refused");
        assert_eq!(with.sections.get("default"), Some(&serde_json::Value::String("allow".into())));
        // A non-object member is carried verbatim and reported; it is not offered as a section object.
        assert_eq!(with.section_error("default"), Some("not_an_object"));
        let without = PolicySet::parse(
            r#"{"version":1,"components":{"c":{"capabilities":{"kv.write":{"allow":["ix/*"]}}}}}"#,
        )
        .expect("the same file without the section parses");
        assert_eq!(with.components, without.components, "an unread member decides no rule");
        assert_eq!(with.unclaimed_sections(&[]), vec!["default"]);
        assert_eq!(without.unclaimed_sections(&[]), Vec::<&str>::new());
    }

    /// The carried sections round-trip: a `PolicySet` read from a file and written back keeps `mesh`, so
    /// a tool that rewrites the policy cannot lose the section a *different* crate reads.
    #[test]
    fn carried_sections_round_trip_through_serde() {
        let set = PolicySet::parse(
            r#"{"version":1,"mesh":{"version":1,"enabled":true,"roster_key":""},"components":{}}"#,
        )
        .expect("parses");
        let text = serde_json::to_string(&set).expect("serialises");
        let back: PolicySet = serde_json::from_str(&text).expect("reads back");
        assert_eq!(back.section("mesh").and_then(|m| m.get("enabled")), Some(&serde_json::Value::Bool(true)));
        assert_eq!(back.section_errors, set.section_errors, "errors are a load report, not file content");
    }

    #[test]
    fn zero_rates_and_caps_are_refused() {
        let rate = |json: &str| PolicySet::parse(json);
        assert!(rate(r#"{"version":1,"components":{"c":{"capabilities":{"x":{"rate":{"per_minute":0}}}}}}"#).is_err());
        assert!(rate(r#"{"version":1,"components":{"c":{"capabilities":{"x":{"rate":{"per_minute":1,"burst":0}}}}}}"#).is_err());
        assert!(rate(r#"{"version":1,"components":{"c":{"capabilities":{"x":{"daily_cap":0}}}}}}"#).is_err());
        assert!(rate(r#"{"version":1,"components":{"c":{"capabilities":{"":{"daily_cap":2}}}}}}"#).is_err());
    }

    #[test]
    fn effect_deny_with_lists_is_refused_as_confusing() {
        let err = PolicySet::parse(
            r#"{"version":1,"components":{"c":{"capabilities":{"x":{"effect":"deny","allow":["*"]}}}}}"#,
        )
        .unwrap_err();
        assert!(err.0.contains("effect \"deny\""), "{}", err.0);
    }

    #[test]
    fn sensitivity_comes_from_rule_flag_then_lists() {
        let set = PolicySet::parse(
            r#"{"version":1,"sensitive_capabilities":["kv.scan"],
                 "components":{"c":{"capabilities":{
                    "whatsapp.send":{"sensitive":false},
                    "mqtt.publish":{"sensitive":true}}}}}"#,
        )
        .unwrap();
        assert!(!set.is_sensitive("c", "whatsapp.send")); // explicit override wins
        assert!(set.is_sensitive("c", "mqtt.publish"));
        assert!(set.is_sensitive("c", "credentials.read")); // built-in
        assert!(set.is_sensitive("c", "kv.scan")); // file list
        assert!(!set.is_sensitive("c", "log.write"));
        // the built-in list is not component-scoped: an unknown component is denied the same way
        assert!(set.is_sensitive("other", "credentials.read"));
    }

    #[test]
    fn empty_policy_is_valid_and_speaks_the_current_schema() {
        let set = PolicySet::empty();
        assert_eq!(set.version, SCHEMA_VERSION);
        assert_eq!(serde_json::from_str::<PolicySet>(&serde_json::to_string(&set).unwrap()).unwrap(), set);
    }
}
