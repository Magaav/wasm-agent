//! The access-control hook: who may publish and subscribe where.
//!
//! The bus never decides authority on its own beyond one rule, which the kernel already has in
//! writing (docs/BUS.md, docs/KERNEL.md): **a component may publish and subscribe inside its own
//! namespace, and nowhere else unless a manifest grant names the pattern**. That rule is
//! [`NamespaceAcl`], the default. A host that keeps grants elsewhere implements [`Access`] itself
//! and installs it with [`crate::Bus::set_access`].
//!
//! Enforcement is at the two doors: [`crate::Bus::publish`] checks the event's `source` against the
//! event's topic, [`crate::Bus::subscribe`] checks the owner against the whole pattern it asks for.
//! A pattern is checked as a *set*: a grant for `whatsapp.*` authorises `whatsapp.transcript.*`
//! (narrower) and refuses `*` (broader).

use crate::topic::{Pattern, Topic};
use std::fmt;

/// Which door.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Action {
    Publish,
    Subscribe,
}

impl Action {
    pub fn as_str(self) -> &'static str {
        match self {
            Action::Publish => "publish",
            Action::Subscribe => "subscribe",
        }
    }
}

impl fmt::Display for Action {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// What the host implements. Both methods are called without the bus lock held, so an
/// implementation may look at its own state (it must not call back into this bus: that would be a
/// self-deadlock only if it published from inside a check, which is not a thing an ACL does).
pub trait Access: Send + Sync {
    /// May `source` publish to `topic`?
    fn may_publish(&self, source: &str, topic: &Topic) -> bool;
    /// May `owner` subscribe to everything `pattern` matches?
    fn may_subscribe(&self, owner: &str, pattern: &Pattern) -> bool;
}

/// Everything allowed. Only for a bus that is not the trust boundary (tests, or a host that has
/// already checked the caller before it got here). Never the default.
#[derive(Debug, Default, Clone, Copy)]
pub struct AllowAll;

impl Access for AllowAll {
    fn may_publish(&self, _source: &str, _topic: &Topic) -> bool {
        true
    }
    fn may_subscribe(&self, _owner: &str, _pattern: &Pattern) -> bool {
        true
    }
}

/// Nothing allowed. For a bus that is up but has no grants yet.
#[derive(Debug, Default, Clone, Copy)]
pub struct DenyAll;

impl Access for DenyAll {
    fn may_publish(&self, _source: &str, _topic: &Topic) -> bool {
        false
    }
    fn may_subscribe(&self, _owner: &str, _pattern: &Pattern) -> bool {
        false
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Grant {
    component: String,
    action: Action,
    pattern: Pattern,
}

/// The default policy: own namespace, plus explicit grants.
///
/// A component's own namespace is the first topic segment equal to its id: `wa-whatsapp` owns
/// `wa-whatsapp.*`. `publish` to `whatsapp.transcript.ready` needs either `source == "whatsapp"` or
/// a `Publish` grant (from the manifest capability `bus`) whose pattern matches that topic.
#[derive(Debug, Default, Clone)]
pub struct NamespaceAcl {
    grants: Vec<Grant>,
}

impl NamespaceAcl {
    /// Own namespace only: the strict default.
    pub fn new() -> NamespaceAcl {
        NamespaceAcl { grants: Vec::new() }
    }

    /// Record a grant. `pattern` is `"a.b"`, `"a.*"` or `"*"`.
    pub fn grant(
        &mut self,
        component: &str,
        action: Action,
        pattern: &str,
    ) -> Result<(), crate::topic::TopicError> {
        let pattern = Pattern::parse(pattern)?;
        if component.is_empty() {
            return Err(crate::topic::TopicError::Empty);
        }
        self.grants.push(Grant { component: component.to_string(), action, pattern });
        Ok(())
    }

    /// Convenience for a manifest grant object: both doors at once.
    pub fn grant_both(
        &mut self,
        component: &str,
        pattern: &str,
    ) -> Result<(), crate::topic::TopicError> {
        self.grant(component, Action::Publish, pattern)?;
        self.grant(component, Action::Subscribe, pattern)
    }

    /// The grants, as `component action pattern` lines. For a log or a `dump`; contains no secrets.
    pub fn describe(&self) -> Vec<String> {
        self.grants
            .iter()
            .map(|g| format!("{} {} {}", g.component, g.action, g.pattern.as_written()))
            .collect()
    }

    fn granted(&self, component: &str, action: Action, pattern: &Pattern) -> bool {
        self.grants.iter().any(|g| {
            g.component == component && g.action == action && g.pattern.covers(pattern)
        })
    }
}

/// Is `pattern` inside the namespace `owner` owns? `wa-whatsapp` covers `wa-whatsapp` itself,
/// `wa-whatsapp.transcript` and `wa-whatsapp.transcript.*`, and nothing wider.
fn own_namespace_covers(owner: &str, pattern: &Pattern) -> bool {
    match pattern {
        Pattern::Exact(t) => t.namespace() == owner,
        Pattern::Prefix(p) => {
            p == owner
                || (p.len() > owner.len()
                    && p.starts_with(owner)
                    && p.as_bytes()[owner.len()] == b'.')
        }
    }
}

impl Access for NamespaceAcl {
    fn may_publish(&self, source: &str, topic: &Topic) -> bool {
        if source.is_empty() {
            return false;
        }
        if topic.namespace() == source {
            return true;
        }
        self.granted(source, Action::Publish, &Pattern::Exact(topic.clone()))
    }

    fn may_subscribe(&self, owner: &str, pattern: &Pattern) -> bool {
        if owner.is_empty() {
            return false;
        }
        if own_namespace_covers(owner, pattern) {
            return true;
        }
        self.granted(owner, Action::Subscribe, pattern)
    }
}
