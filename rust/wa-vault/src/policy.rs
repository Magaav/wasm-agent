//! The `vault` section of `policy.json`: who may reveal what.
//!
//! ```json
//! {
//!   "vault": {
//!     "reveal": [
//!       { "component": "wa-email", "entry": "smtp-password" },
//!       { "component": "wa-whatsapp", "entry": "*" }
//!     ]
//!   }
//! }
//! ```
//!
//! Only `reveal` is here: `use_by_ref` is the kernel's alone and `sign` is authorized by the entry's
//! own `allowed` list, so neither has a policy key that could be written by accident. The section is
//! parsed with `deny_unknown_fields`, so `vault: { "reval": [...] }` is a load error rather than a
//! policy that silently grants nothing (or everything).
//!
//! `entry: "*"` is allowed on purpose: a component that owns a whole namespace (the WhatsApp
//! component's media keys) gets one line instead of a list that drifts. `component: "*"` is **not**
//! special-cased - a wildcard component would be a grant that names nobody, which is how a policy
//! stops being readable. Write the component's name.
use serde::Deserialize;

use crate::Actor;

/// One `vault.reveal` grant.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RevealGrant {
    /// The component's manifest name (`wa-email`), as `Actor::Component` carries it.
    pub component: String,
    /// The entry name, or `*`.
    pub entry: String,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
struct Section {
    #[serde(default)]
    reveal: Vec<RevealGrant>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Policy {
    reveal: Vec<RevealGrant>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PolicyError(pub String);

impl std::fmt::Display for PolicyError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for PolicyError {}

impl Policy {
    pub fn new(reveal: Vec<RevealGrant>) -> Self {
        Policy { reveal }
    }

    pub fn grants(&self) -> &[RevealGrant] {
        &self.reveal
    }

    /// Read the `vault` section out of a `policy.json` document. Every other section is ignored (this
    /// crate is not the policy reader), but a `vault` section that does not parse is an error: a
    /// broken grant must not become "no grants" without anyone noticing.
    pub fn from_policy_json(text: &str) -> Result<Self, PolicyError> {
        let document: serde_json::Value =
            serde_json::from_str(text).map_err(|_| PolicyError("policy_unreadable".to_string()))?;
        match document.get("vault") {
            None | Some(serde_json::Value::Null) => Ok(Policy::default()),
            Some(section) => {
                let section: Section = serde_json::from_value(section.clone())
                    .map_err(|error| PolicyError(format!("policy_vault_invalid:{error}")))?;
                Ok(Policy { reveal: section.reveal })
            }
        }
    }

    /// A component named by a grant for this entry (exact name, or `*` for the entry).
    pub fn allows_reveal(&self, actor: &Actor, name: &str) -> bool {
        let Actor::Component(component) = actor else {
            // Kernel and operator are the vault's owners; a grant exists for guests.
            return true;
        };
        self.reveal
            .iter()
            .any(|grant| grant.component == *component && (grant.entry == "*" || grant.entry == name))
    }
}
