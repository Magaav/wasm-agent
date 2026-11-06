//! The policy model: JSON in, validated rules out.
//!
//! Schema (version 1), all field names snake_case, unknown fields are a **load error** so a typo
//! (`per_minutes`, `require_aprovall`) can never silently drop a limit:
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
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PolicySet {
    pub version: u32,
    /// Capabilities this node treats as sensitive in addition to [`DEFAULT_SENSITIVE`].
    #[serde(default)]
    pub sensitive_capabilities: Vec<String>,
    #[serde(default)]
    pub components: BTreeMap<String, ComponentPolicy>,
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
        let set: PolicySet = serde_json::from_str(text)
            .map_err(|e| PolicyError(format!("not valid JSON for schema {SCHEMA_VERSION}: {e}")))?;
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
        PolicySet { version: SCHEMA_VERSION, sensitive_capabilities: Vec::new(), components: BTreeMap::new() }
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

    #[test]
    fn unknown_fields_and_wrong_versions_are_refused() {
        // "per_minutes" is the typo this test exists for.
        assert!(PolicySet::parse(r#"{"version":1,"components":{"c":{"capabilities":{"x":{"rate":{"per_minutes":5}}}}}}"#).is_err());
        assert!(PolicySet::parse(r#"{"version":2,"components":{}}"#).is_err());
        assert!(PolicySet::parse(r#"{"version":1,"components":{},"default":"allow"}"#).is_err());
        assert!(PolicySet::parse(r#"{"version":1,"components":{"c":{"capabilites":{}}}}"#).is_err());
        assert!(PolicySet::parse("{}").is_err());
        assert!(PolicySet::parse("not json").is_err());
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
